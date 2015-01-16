# vars: EJSONKeyedMap<string, TypedSet>
@evaluateFormula = (model, vars, formula) ->
  switch formula[0]
    when 'var'
      name = formula[1]
      val = vars.get(name)
      unless val?
        throw new EvaluationError()
      return val
    #when 'navigate'
    else
      throw new EvaluationError()
