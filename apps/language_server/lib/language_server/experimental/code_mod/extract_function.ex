defmodule ElixirLS.LanguageServer.Experimental.CodeMod.ExtractFunction do
  @moduledoc """
  Elixir refactoring functions.
  """

  alias Sourceror.Zipper, as: Z

  @doc """
  Return zipper containing AST with extracted function.
  """
  def extract_function(zipper, start_line, end_line, function_name) do
    function_name =
      if is_binary(function_name), do: String.to_atom(function_name), else: function_name

    {quoted_after_extract, acc} = extract_lines(zipper, start_line, end_line, function_name)
    if Enum.empty?(acc.lines) do
      {:error, :not_extractable}
    else
      new_function_zipper = new_function(function_name, [], acc.lines) |> Z.zip()
      declared_vars = vars_declared(new_function_zipper) |> Enum.uniq()
      used_vars = vars_used(new_function_zipper) |> Enum.uniq()

      args = used_vars -- declared_vars
      returns = declared_vars |> Enum.filter(&(&1 in acc.vars))

      {zipper, extracted} =
        add_returned_vars(Z.zip(quoted_after_extract), returns, function_name, args, acc.lines)

      enclosing = acc.def

      zipper
      |> top_find(fn
        {:def, _meta, [{^enclosing, _, _}, _]} -> true
        _ -> false
      end)
      |> Z.insert_right(extracted)
      |> fix_block()
      |> Z.root()
    end
  end

  @doc """
  Return zipper containing AST for lines in the range from-to.
  """
  def extract_lines(zipper, start_line, end_line, replace_with \\ nil) do
    remove_range(zipper, start_line, end_line, %{
      lines: [],
      def: nil,
      def_end: nil,
      vars: [],
      replace_with: replace_with
    })
  end

  defp next_remove_range(zipper, from, to, acc) do
    if next = Z.next(zipper) do
      remove_range(next, from, to, acc)
    else
      # return zipper with lines removed
      {
        elem(Z.top(zipper), 0),
        %{acc | lines: Enum.reverse(acc.lines), vars: Enum.reverse(acc.vars)}
      }
    end
  end

  defp remove_range({{:def, meta, [{marker, _, _}, _]}, _list} = zipper, from, to, acc) do
    acc =
      if meta[:line] < from do
        x = put_in(acc.def, marker)
        put_in(x.def_end, meta[:end][:line])
      else
        acc
      end

    next_remove_range(zipper, from, to, acc)
  end

  defp remove_range({{marker, meta, children}, _list} = zipper, from, to, acc) do
    if meta[:line] < from || meta[:line] > to || marker == :__block__ do
      next_remove_range(
        zipper,
        from,
        to,
        if meta[:line] > to && meta[:line] < acc.def_end && is_atom(marker) && is_nil(children) do
          put_in(acc.vars, [marker | acc.vars] |> Enum.uniq())
        else
          acc
        end
      )
    else
      acc = put_in(acc.lines, [Z.node(zipper) | acc.lines])

      if is_nil(acc.replace_with) do
        zipper
        |> Z.remove()
        |> next_remove_range(from, to, acc)
      else
        function_name = acc.replace_with
        acc = put_in(acc.replace_with, nil)

        zipper
        |> Z.replace({function_name, [], []})
        |> next_remove_range(from, to, acc)
      end
    end
  end

  defp remove_range(zipper, from, to, acc) do
    next_remove_range(zipper, from, to, acc)
  end

  defp vars_declared(new_function_zipper) do
    vars_declared(new_function_zipper, %{vars: []})
  end

  defp vars_declared(nil, acc) do
    Enum.reverse(acc.vars)
  end

  defp vars_declared({{:=, _, [{var, _, nil}, _]}, _rest} = zipper, acc) when is_atom(var) do
    zipper
    |> Z.next()
    |> vars_declared(put_in(acc.vars, [var | acc.vars]))
  end

  defp vars_declared(zipper, acc) do
    zipper
    |> Z.next()
    |> vars_declared(acc)
  end

  defp vars_used(new_function_zipper) do
    vars_used(new_function_zipper, %{vars: []})
  end

  defp vars_used(nil, acc) do
    Enum.reverse(acc.vars)
  end

  defp vars_used({{marker, _meta, nil}, _rest} = zipper, acc) when is_atom(marker) do
    zipper
    |> Z.next()
    |> vars_used(put_in(acc.vars, [marker | acc.vars]))
  end

  defp vars_used(zipper, acc) do
    zipper
    |> Z.next()
    |> vars_used(acc)
  end

  defp add_returned_vars(zipper, _returns = [], function_name, args, lines) do
    args = var_ast(args)

    {
      replace_function_call(zipper, function_name, {function_name, [], args}),
      new_function(function_name, args, lines)
    }
  end

  defp add_returned_vars(zipper, returns, function_name, args, lines) when is_list(returns) do
    args = var_ast(args)
    returned_vars = returned(returns)

    {
      replace_function_call(
        zipper,
        function_name,
        {:=, [], [returned_vars, {function_name, [], args}]}
      ),
      new_function(function_name, args, Enum.concat(lines, [returned_vars]))
    }
  end

  defp var_ast(vars) when is_list(vars) do
    Enum.map(vars, &var_ast/1)
  end

  defp var_ast(var) when is_atom(var) do
    {var, [], nil}
  end

  defp returned([var]) when is_atom(var) do
    var_ast(var)
  end

  defp returned(vars) when is_list(vars) do
    returned = vars |> var_ast() |> List.to_tuple()
    {:__block__, [], [returned]}
  end

  defp replace_function_call(zipper, function_name, replace_with) do
    zipper
    |> top_find(fn
      {^function_name, [], []} -> true
      _ -> false
    end)
    |> Z.replace(replace_with)
  end

  defp new_function(function_name, args, lines) do
    {:def, [do: [], end: []],
     [
       {function_name, [], args},
       [
         {
           {:__block__, [], [:do]},
           {:__block__, [], lines}
         }
       ]
     ]}
  end

  defp fix_block(zipper) do
    zipper
    |> top_find(fn
      {:{}, [], _children} -> true
      _ -> false
    end)
    |> case do
      nil ->
        zipper

      {{:{}, [], [block | defs]}, meta} ->
        {
          {
            block,
            {:__block__, [], defs}
          },
          meta
        }
    end
  end

  defp top_find(zipper, function) do
    zipper
    |> Z.top()
    |> Z.find(function)
  end
end
