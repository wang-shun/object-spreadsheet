
# Future: Make this better.
standardServerCallback = (error, result) ->
  if error?
    alert('The operation failed on the server: ' + error.message)

andThen = (cont) ->
  (error, result) ->
    if error?
      standardServerCallback(arguments...)
    else
      cont(result)


fullTextToShow = new ReactiveVar(null)
isLoading = new ReactiveVar(true)

Template.formulaValueBar.helpers
  loading: -> isLoading.get()
  fullTextToShow: -> fullTextToShow.get()
  addStateCellArgs: -> addStateCellArgs.get()
  changeColumnArgs: -> changeColumnArgs.get()

#
# Template addStateCell
#
addStateCellArgs = new ReactiveVar([], EJSON.equals)

Template.addStateCell.events({
  'submit form': (event, template) ->
    try
      inputField = template.find('input[name=value]')
      valueStr = inputField?.value
      StateEdit.addCell @qFamilyId, valueStr,
      # Clear the field on successful submission (only)
      andThen -> if inputField? then inputField.value = ''
    catch e
      console.error e
    false # prevent clear
})

#
# Template changeColumn
#
changeColumnArgs = new ReactiveVar([], EJSON.equals)

stringifyType = (type) ->
  if typeIsPrimitive(type) then type
  else
    c = getColumn(type)
    if c?
      objName = if c.parent then getColumn(c.parent).objectName else ""
      prefix = if objName? then "#{objName}:" else ""
      prefix + c.objectName
    else
      "?<#{type}>"
    
# We mainly care that this doesn't crash.
origFormulaStrForColumnId = (columnId) ->
  formula = getColumn(columnId)?.formula
  formula && stringifyFormula(getColumn(columnId).parent, formula)
newFormulaStr = new ReactiveVar(null)
origDisplayStrForColumnId = (columnId) ->
  formula = getColumn(columnId)?.display
  formula && stringifyFormula(getColumn(columnId).type, formula) ? ''
newDisplayStr = new ReactiveVar(null)
newDisplayStr.initial = new ReactiveVar(null)
Template.changeColumn.rendered = () ->
  formula = origFormulaStrForColumnId(Template.currentData().columnId)
  newFormulaStr.set(formula)
  if formula?
    changeColumnInitFormulaBar(this)
  display = origDisplayStrForColumnId(Template.currentData().columnId)
  newDisplayStr.set(display) ; newDisplayStr.initial.set(display)
  @find('input[name=display]')?.value = display
Template.changeColumn.helpers
  columnName: ->
    c = getColumn(@columnId)
    objName = if c.parent then getColumn(c.parent).objectName else ""
    prefix = if objName? then "#{objName}:" else ""
    prefix + (c?.objectName ? c?.fieldName ? '<unnamed>')
  columnType: ->
    c = getColumn(@columnId)
    if c?.type then stringifyType(c.type) else ''
  columnSpecifiedType: ->
    c = getColumn(@columnId)
    if c?.specifiedType then stringifyType(c.specifiedType) else ''
  formula: ->
    origFormulaStrForColumnId(@columnId)
  formulaClass: ->
    if newFormulaStr.get() != origFormulaStrForColumnId(@columnId) then 'formulaModified'
  displayClass: ->
    if newDisplayStr.get() != newDisplayStr.initial.get() then 'formulaModified'
  contextText: ->
    col = getColumn(@columnId)
    if col.isObject
      objectNameWithFallback(getColumn(col.parent)) ? '<unnamed>'
    else null
  contextColorIndex: ->
    col = getColumn(@columnId)
    if col.isObject
      colorIndexForDepth(columnDepth(col.parent))
    else null

changeColumnInitFormulaBar = (template) ->
  formula = origFormulaStrForColumnId(template.data.columnId)
  template.codeMirror = CodeMirror(template.find('#changeFormula-formula'), {
    value: formula
    extraKeys: {
      Enter: (cm) => changeColumnSubmit(template)
    }
    })
  # http://stackoverflow.com/a/15256593
  template.codeMirror.setSize('100%', template.codeMirror.defaultTextHeight() + 2 * 4)
  template.codeMirror.on('changes', (cm) ->
    newFormulaStr.set(cm.getDoc().getValue()))

changeColumnSubmit = (template) ->
  try
    # Set the type
    newVal = template.find('input[name=type]').value
    parsed = false
    try
      type = if newVal == '' then null else parseTypeStr(newVal)
      parsed = true
    catch e
      alert("Invalid type '#{newVal}'.")
      return false
    if parsed
      Meteor.call 'changeColumnSpecifiedType', $$, template.data.columnId, type,
                  standardServerCallback
    # Set the formula
    formulaStr = newFormulaStr.get()
    if formulaStr?
      if formulaStr == ''
        formula = null   # remove formula
      else
        try
          formula = parseFormula(getColumn(template.data.columnId).parent, formulaStr)
        catch e
          unless e instanceof FormulaValidationError
            throw e
          alert('Failed to parse formula: ' + e.message)
          return false
        # Canonicalize the string in the field, otherwise the field might stay
        # yellow after successful submission.
        formulaStr = stringifyFormula(getColumn(template.data.columnId).parent, formula)
        template.codeMirror?.getDoc().setValue(formulaStr)
        newFormulaStr.set(formulaStr)
      Meteor.call('changeColumnFormula', $$,
                  template.data.columnId,
                  formula,
                  standardServerCallback)
    # Set the display
    displayStr = newDisplayStr.get()
    if displayStr? && displayStr != newDisplayStr.initial.get()
      if displayStr == ''
        display = null   # revert to default
      else
        try
          display = parseFormula(getColumn(template.data.columnId).type, displayStr)
        catch e
          unless e instanceof FormulaValidationError
            throw e
          alert('Failed to parse display formula: ' + e.message)
          return false
        # Canonicalize the string in the field, otherwise the field might stay
        # yellow after successful submission.
        displayStr = stringifyFormula(getColumn(template.data.columnId), display)
        template.find('input[name=display]').value = displayStr
        newDisplayStr.set(displayStr) ; newDisplayStr.initial.set(displayStr)
      Meteor.call('changeColumnDisplay', $$,
                  template.data.columnId,
                  display,
                  standardServerCallback)
  catch e
    console.error e

Template.changeColumn.events
  'input .display': (event, template) ->
    newDisplayStr.set(event.target.value) #template.find('input[name=display]').value)
  'submit form': (event, template) ->
    changeColumnSubmit(template)
    false # prevent refresh
  'click [type=reset]': (event, template) ->
    orig = origFormulaStrForColumnId(@columnId)
    newFormulaStr.set(orig)
    template.codeMirror?.getDoc().setValue(orig)
    newDisplayStr.set(newDisplayStr.initial.get())
    template.find('input[name=display]')?.value = newDisplayStr.initial.get()
    false # prevent clear
  'click .create': (event, template) ->
    # Default formula to get the new column created ASAP.
	# Then the user can edit it as desired.
    formula = DUMMY_FORMULA
    Meteor.call 'changeColumnFormula', $$, @columnId, formula,
                standardServerCallback
    # TODO warn user if column has data!!
    # It's ugly to code this state transition manually.  I considered
    # introducing a child template, but it's unclear how the parent and child
    # templates can reference each other. ~ Matt 2015-09-30
    newFormulaStr.set(origFormulaStrForColumnId(@columnId))
    # Have to wait for the template to re-render with the new div.
    Tracker.afterFlush(() -> changeColumnInitFormulaBar(template))
  'keydown form': (event, template) ->
    if (event.which == 27) then template.find("[type=reset]")?.click()

# Needed for the formula div to get added during the "Create formula" handler,
# rather than sometime later when we get the update from the server.
Meteor.methods({
  changeColumnFormula: (cc, columnId, formula) ->
    Columns.update(columnId, {$set: {formula: formula}})
})



exported {ActionBar: {fullTextToShow, isLoading, addStateCellArgs, changeColumnArgs}, standardServerCallback, andThen}
