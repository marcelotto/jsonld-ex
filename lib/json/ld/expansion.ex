defmodule JSON.LD.Expansion do
  @moduledoc nil

  import JSON.LD


  @doc """
  Expands the given input according to the steps in the JSON-LD Expansion Algorithm.

  > Expansion is the process of taking a JSON-LD document and applying a `@context`
  > such that all IRIs, types, and values are expanded so that the `@context` is
  > no longer necessary.

  -- <https://www.w3.org/TR/json-ld/#expanded-document-form>

  Details at <http://json-ld.org/spec/latest/json-ld-api/#expansion-algorithm>
  """
  def expand(json_ld_object, opts \\ []) do
    case do_expand(JSON.LD.Context.new(opts), nil, json_ld_object, Keyword.delete(opts, :base)) do
      result = %{"@graph" => graph} when map_size(result) == 1 ->
        graph
      nil ->
        []
      result when not is_list(result) ->
        [result]
      result -> result
    end
  end

  defp do_expand(active_context, active_property, element, opts \\ [])

  # 1) If element is null, return null.
  defp do_expand(_, _, nil, _), do: nil

  # 2) If element is a scalar, ...
  defp do_expand(active_context, active_property, element, opts)
        when is_binary(element) or is_number(element) or is_boolean(element) do
    if active_property in [nil, "@graph"] do
      nil
    else
      expand_value(active_context, active_property, element)
    end
  end

  # 3) If element is an array, ...
  defp do_expand(active_context, active_property, element, opts)
        when is_list(element) do
    term_def = active_context.term_defs[active_property]
    container_mapping = term_def && term_def.container_mapping
    element
    |> Enum.reduce([], fn (item, result) ->
        expanded_item = do_expand(active_context, active_property, item)
        if (active_property == "@list" or container_mapping == "@list") and
            (is_list(expanded_item) or Map.has_key?(expanded_item, "@list")),
          do: raise JSON.LD.ListOfListsError,
                message: "List of lists in #{inspect element}"
        case expanded_item do
          nil -> result
          list when is_list(list) ->
            result ++ list
          expanded_item ->
            result ++ [expanded_item]
        end
    end)
  end

  # 4) - 13)
  defp do_expand(active_context, active_property, element, opts)
        when is_map(element) do
    # 5)
    if Map.has_key?(element, "@context") do
      active_context = JSON.LD.Context.update(active_context, Map.get(element, "@context"))
    end
    # 6) and 7)
    result = element
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.reduce(%{}, fn ({key, value}, result) ->
      if (key != "@context") &&  # 7.1)
          (expanded_property = expand_iri(key, active_context, false, true)) && # 7.2)
          (String.contains?(expanded_property, ":") || keyword?(expanded_property)) do  # 7.3)
        if keyword?(expanded_property) do  # 7.4)
          if active_property == "@reverse", # 7.4.1)
            do: raise JSON.LD.InvalidReversePropertyMapError,
                  message: "An invalid reverse property map has been detected. No keywords apart from @context are allowed in reverse property maps."
          if Map.has_key?(result, expanded_property), # 7.4.2)
            do: raise JSON.LD.CollidingKeywordsError,
                  message: "Two properties which expand to the same keyword have been detected. This might occur if a keyword and an alias thereof are used at the same time."

          expanded_value = case expanded_property do
            "@id" -> # 7.4.3)
              if is_binary(value) do
                expand_iri(value, active_context, true)
              else
                raise JSON.LD.InvalidIdValueError,
                        message: "#{inspect value} is not a valid @id value"
              end
            "@type" -> # 7.4.4)
              cond do
                is_binary(value) ->
                  expand_iri(value, active_context, true, true)
                is_list(value) and Enum.all?(value, &is_binary/1) ->
                  Enum.map value, fn item ->
                    expand_iri(item, active_context, true, true) end
                true ->
                  raise JSON.LD.InvalidTypeValueError,
                          message: "#{inspect value} is not a valid @type value"
              end
            "@graph" -> # 7.4.5)
              do_expand(active_context, "@graph", value, opts)
            "@value" -> # 7.4.6)
              if scalar?(value) or is_nil(value) do
                if is_nil(value) do
                  {:skip, Map.put(result, "@value", nil)}
                else
                  value
                end
              else
                raise JSON.LD.InvalidValueObjectValueError,
                  message: "#{inspect value} is not a valid value for the @value member of a value object; neither a scalar nor null"
              end
            "@language" -> # 7.4.7)
              if is_binary(value),
                do: String.downcase(value),
                else: raise JSON.LD.InvalidLanguageTaggedStringError,
                        message: "#{inspect value} is not a valid language-tag"
            "@index" -> # 7.4.8)
              if is_binary(value),
                do: value,
                else: raise JSON.LD.InvalidIndexValueError,
                        message: "#{inspect value} is not a valid @index value"
            "@list" -> # 7.4.9)
              if active_property in [nil, "@graph"] do  # 7.4.9.1)
                {:skip, result}
              else
                value = do_expand(active_context, active_property, value, opts)

                # Spec FIXME: need to be sure that result is a list [from RDF.rb implementation]
                value = if is_list(value),
                  do: value,
                  else: [value]

                # If expanded value is a list object, a list of lists error has been detected and processing is aborted.
                # Spec FIXME: Also look at each object if result is a list [from RDF.rb implementation]
                if Enum.any?(value, fn v -> Map.has_key?(v, "@list") end),
                  do: raise JSON.LD.ListOfListsError,
                        message: "List of lists in #{inspect value}"
                value
              end
            "@set" -> # 7.4.10)
              do_expand(active_context, active_property, value, opts)
            "@reverse" -> # 7.4.11)
              unless is_map(value),
                do: raise JSON.LD.InvalidReverseValueError,
                      message: "#{inspect value} is not a valid @reverse value"
              expanded_value = do_expand(active_context, "@reverse", value, opts) # 7.4.11.1)
              new_result =
                if Map.has_key?(expanded_value, "@reverse") do  # 7.4.11.2) If expanded value contains an @reverse member, i.e., properties that are reversed twice, execute for each of its property and item the following steps:
                  Enum.reduce expanded_value["@reverse"], result,
                    fn ({property, item}, new_result) ->
                      items = if is_list(item),
                        do: item,
                        else: [item]
                      Map.update(new_result, property, items, fn members ->
                        members ++ items
                      end)
                  end
                else
                  result
                end
              if Map.keys(expanded_value) != ["@reverse"] do  # 7.4.11.3)
                reverse_map =
                  Enum.reduce expanded_value, Map.get(new_result, "@reverse", %{}), fn
                    ({property, items}, reverse_map) when property != "@reverse" ->
                      Enum.each(items, fn item ->
                        if Map.has_key?(item, "@value") or Map.has_key?(item, "@list"),
                          do: raise JSON.LD.InvalidReversePropertyValueError,
                               message: "invalid value for a reverse property in #{inspect item}"
                      end)
                      Map.update(reverse_map, property, items, fn members ->
                        members ++ items
                      end)
                    (_, reverse_map) -> reverse_map
                  end
                new_result = Map.put(new_result, "@reverse", reverse_map)
              end
              {:skip, new_result}
            _ ->
              nil
          end
          # 7.4.12)
          case expanded_value do
            nil ->
              result
            {:skip, new_result} ->
              new_result
            expanded_value ->
              Map.put(result, expanded_property, expanded_value)
          end

        else # expanded_property is not a keyword
          term_def = active_context.term_defs[key]
          expanded_value = cond do
            # 7.5) Otherwise, if key's container mapping in active context is @language and value is a JSON object then value is expanded from a language map as follows:
            is_map(value) && term_def && term_def.container_mapping == "@language" ->
              value
#              |> IO.inspect(label: "value")
              |> Enum.sort_by(fn {language, _} -> language end)
              |> Enum.reduce([], fn ({language, language_value}, language_map_result) ->
                   language_map_result ++ (
                     if(is_list(language_value),
                       do:   language_value,
                       else: [language_value])
                     |> Enum.map(fn
                          item when is_binary(item) ->
                            %{
                              "@value"    => item,
                              "@language" => String.downcase(language)
                            }
                          item ->
                            raise JSON.LD.InvalidLanguageMapValueError,
                              message: "#{inspect item} is not a valid language map value"

                        end)
                   )
#                   |> IO.inspect(label: "result")
                 end)
            # 7.6)
            is_map(value) && term_def && term_def.container_mapping == "@index" ->
              value
              |> Enum.sort_by(fn {index, _} -> index end)
              |> Enum.reduce([], fn ({index, index_value}, index_map_result) ->
                   index_map_result ++ (
                     index_value = if(is_list(index_value),
                       do:   index_value,
                       else: [index_value])
                     index_value = do_expand(active_context, key, index_value, opts)
                     Enum.map(index_value, fn item ->
                        Map.put_new(item, "@index", index)
                     end)
                   )
                 end)
            # 7.7)
            true ->
              do_expand(active_context, key, value, opts)
          end
          # 7.8)
          if is_nil(expanded_value) do
            result
          else
            # 7.9)
            if (term_def && term_def.container_mapping == "@list") &&
                !(is_map(expanded_value) && Map.has_key?(expanded_value, "@list")) do
              expanded_value = %{"@list" =>
                (if is_list(expanded_value),
                  do: expanded_value,
                  else: [expanded_value])}
            end
            # 7.10) Otherwise, if the term definition associated to key indicates that it is a reverse property
            # Spec FIXME: this is not an otherwise [from RDF.rb implementation]
            if term_def && term_def.reverse_property do
              reverse_map = Map.get(result, "@reverse", %{})
              reverse_map =
                if(is_list(expanded_value),
                  do:   expanded_value,
                  else: [expanded_value])
                |> Enum.reduce(reverse_map, fn (item, reverse_map) ->
                     if Map.has_key?(item, "@value") or Map.has_key?(item, "@list"),
                       do: raise JSON.LD.InvalidReversePropertyValueError,
                            message: "invalid value for a reverse property in #{inspect item}"
                     Map.update reverse_map, expanded_property, [item], fn members ->
                       members ++ [item]
                     end
                   end)
              Map.put(result, "@reverse", reverse_map)
            else # 7.11)
              expanded_value = if is_list(expanded_value),
                do: expanded_value,
                else: [expanded_value]
              Map.update result, expanded_property, expanded_value,
                fn values -> expanded_value ++ values end
            end
          end
        end
      else
        result
      end
    end)

    result = case result do
      # 8)
      %{"@value" => value} ->
        with keys = Map.keys(result) do                       # 8.1)
          if Enum.any?(keys, &(not &1 in ~w[@value @language @type @index])) ||
             ("@language" in keys and "@type" in keys) do
            raise JSON.LD.InvalidValueObjectError,
              message: "value object with disallowed members"
          end
        end
        cond do
          value == nil -> nil                                 # 8.2)
          !is_binary(value) and Map.has_key?(result, "@language") ->  # 8.3)
            raise JSON.LD.InvalidLanguageTaggedValueError,
              message: "@value '#{inspect value}' is tagged with a language"
          (type = result["@type"]) && !RDF.uri?(type) ->      # 8.4)
            raise JSON.LD.InvalidTypedValueError,
              message: "@value '#{inspect value}' has invalid type #{inspect type}"
          true -> result
        end
      # 9)
      %{"@type" => type} when not is_list(type) ->
        Map.put(result, "@type", [type])
      # 10)
      %{"@set" => set} ->
        validate_set_or_list_object(result)
        set
      %{"@list" => list} ->
        validate_set_or_list_object(result)
        result
      _ -> result
    end

    # 11) If result contains only the key @language, set result to null.
    if is_map(result) and map_size(result) == 1 and Map.has_key?(result, "@language"),
      do: result = nil

    # 12) If active property is null or @graph, drop free-floating values as follows:
    if active_property in [nil, "@graph"] and (
        Enum.empty?(result) or
        Map.has_key?(result, "@value") or Map.has_key?(result, "@list") or
        (map_size(result) == 1 and Map.has_key?(result, "@id"))),
      do: result = nil

    result
  end

  defp validate_set_or_list_object(object) when map_size(object) == 1, do: true
  defp validate_set_or_list_object(object = %{"@index" => _})
                                           when map_size(object) == 2, do: true
  defp validate_set_or_list_object(object) do
    raise JSON.LD.InvalidSetOrListObjectError,
      message: "set or list object with disallowed members: #{inspect object}"
  end


  @doc """
  Details at <http://json-ld.org/spec/latest/json-ld-api/#value-expansion>
  """
  def expand_value(active_context, active_property, value) do
    with term_def when term_def != nil <- active_context.term_defs[active_property] do
      cond do
        term_def.type_mapping == "@id" ->
          %{"@id" => expand_iri(value, active_context, true, false)}
        term_def.type_mapping == "@vocab" ->
          %{"@id" => expand_iri(value, active_context, true, true)}
        type_mapping = term_def.type_mapping ->
          %{"@value" => value, "@type" => type_mapping}
        is_binary(value) ->
          language_mapping = term_def.language_mapping
          cond do
           language_mapping ->
              %{"@value" => value, "@language" => language_mapping}
           language_mapping == false && active_context.default_language ->
              %{"@value" => value, "@language" => active_context.default_language}
           true ->
            %{"@value" => value}
          end
        true ->
          %{"@value" => value}
      end
    else
      _ -> %{"@value" => value}
    end
  end

end