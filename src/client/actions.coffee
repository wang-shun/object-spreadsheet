
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

NESTED_UNDERLINING_PX_PER_LEVEL = 4
NESTED_UNDERLINING_MAX_DEPTH = 5

# We mainly care that this doesn't crash.
origFormulaStrForColumnId = (columnId) ->
  formula = getColumn(columnId)?.formula
  formula && stringifyFormula(getColumn(columnId).parent, formula)
newFormulaStr = new ReactiveVar(null)
newFormulaInfo = new ReactiveVar(null)

origDisplayStrForColumnId = (columnId) ->
  formula = getColumn(columnId)?.display
  formula && stringifyFormula(getColumn(columnId).type, formula) ? ''
newDisplayStr = new ReactiveVar(null)

origReferenceDisplayStrForColumnId = (columnId) ->
  formula = getColumn(columnId)?.referenceDisplay
  # Note!  "this" type is the column itself, not its (key) type.
  formula && stringifyFormula(columnId, formula) ? ''
newReferenceDisplayStr = new ReactiveVar(null)

Template.changeColumn.rendered = () ->
  formulaStr = origFormulaStrForColumnId(Template.currentData().columnId)
  newFormulaStr.set(formulaStr)
  if formulaStr?
    changeColumnInitFormulaBar(this)
  displayStr = origDisplayStrForColumnId(Template.currentData().columnId)
  newDisplayStr.set(displayStr)
  @find('input[name=display]')?.value = displayStr
  referenceDisplayStr = origReferenceDisplayStrForColumnId(Template.currentData().columnId)
  newReferenceDisplayStr.set(referenceDisplayStr)
  @find('input[name=referenceDisplay]')?.value = referenceDisplayStr

tracingView = null

Template.changeColumn.destroyed = () ->
  # Try to avoid holding on to data that's no longer relevant.
  newFormulaStr.set(null)
  newFormulaInfo.set(null)
  newDisplayStr.set(null)
  newReferenceDisplayStr.set(null)
  tracingView?.destroy()
  tracingView = null

Template.changeColumn.helpers
  columnName: ->
    c = getColumn(@columnId)
    objName =
      if !@isObject && c.isObject then objectNameWithFallback(c)
      else if c.parent then objectNameWithFallback(getColumn(c.parent))
      else ''
    prefix = if objName? then "#{objName}:" else ""
    prefix + ((if @isObject then c.objectName else c.fieldName) ? '<unnamed>')
  columnType: ->
    c = getColumn(@columnId)
    if c?.type then stringifyType(c.type) else ''
  columnSpecifiedType: ->
    c = getColumn(@columnId)
    if c?.specifiedType then stringifyType(c.specifiedType) else ''
  formula: ->  # Used to test whether the formula box should appear.
    origFormulaStrForColumnId(@columnId)
  formulaClass: ->
    if newFormulaStr.get() != origFormulaStrForColumnId(@columnId) then 'formulaModified'
  newFormulaInfo: ->
    newFormulaInfo.get()
  displayClass: ->
    if newDisplayStr.get() != origDisplayStrForColumnId(@columnId) then 'formulaModified'
  referenceDisplayClass: ->
    if newReferenceDisplayStr.get() != origReferenceDisplayStrForColumnId(@columnId) then 'formulaModified'
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
  template.codeMirror.setSize('100%', template.codeMirror.defaultTextHeight() + 2 * 4 +
                              NESTED_UNDERLINING_PX_PER_LEVEL * NESTED_UNDERLINING_MAX_DEPTH)
  template.codeMirror.on('beforeChange', (cm, change) ->
    newtext = change.text.join('').replace(/\n/g, '')
    change.update(null, null, [newtext])
    true)
  template.codeMirror.on('changes', (cm) ->
    newFormulaStr.set(cm.getDoc().getValue())
    updateFormulaView(template))
  updateFormulaView(template)

updateFormulaView = (template) ->
  formulaStr = newFormulaStr.get()
  parentColumnId = getColumn(template.data.columnId).parent
  try
    formula = parseFormula(parentColumnId, formulaStr)
    # Fill in vars expando field on all subformulas.  Obviously in the future
    # we want to be able to help troubleshoot ill-typed formulas, but we punt
    # all error tolerance until later rather than fight that complexity now.
    typecheckFormula(liteModel, new EJSONKeyedMap([['this', parentColumnId]]), formula)
  catch e
    unless e instanceof FormulaValidationError
      throw e
    # TODO: More graceful error handling
    newFormulaInfo.set(null)
    return
  root = getSubformulaTree(formula)
  bands = []
  layoutSubtree = (node) ->
    node.ch1 = node.formula.loc.first_column
    node.ch2 = node.formula.loc.last_column
    node.height = 0
    for child, i in node.children
      # loc missing for implicit "this" inserted by resolveNavigation; other cases?
      if child.formula.loc?
        layoutSubtree(child)
        isNavigationLhs = (node.formula[0] in ['up', 'down'] && i == 0)
        if isNavigationLhs
          node.ch1 = child.ch2
        node.height = Math.max(node.height, child.height + !isNavigationLhs)
    top = 4 + template.codeMirror.defaultTextHeight() + 1 + NESTED_UNDERLINING_PX_PER_LEVEL * node.height
    # Tweak for gaps in navigation chains.
    x1 = template.codeMirror.cursorCoords({line: 0, ch: node.ch1}, 'local').left + 1
    x2 = template.codeMirror.cursorCoords({line: 0, ch: node.ch2}, 'local').left - 1
    bands.push({
      node: node
      selected: false
      left: x1
      width: x2 - x1
      top: top
      height: 2
      })
  layoutSubtree(root)
  newFormulaInfo.set({root: root, bands: bands, selectedBand: null, haveTraced: false})

class TracingView
  constructor: (domElement) ->
    @hot = new Handsontable(domElement, {})  # Needs a lot of work
  show: (formula) ->
    # TODO: Enforce outside-to-inside order ourselves rather than relying on it
    # as a side effect of object iteration order and the way we typecheck
    # formulas.
    varsAndTypesList = formula.vars.entries()
    grid = [(new ViewCell(name) for [name, _] in varsAndTypesList)]
    grid[0].push(new ViewCell('Result'))
    for [varValues, outcome] in formula.traces.entries()
      line = (new ViewCell(varValues.get(name).elements()[0]) for [name, _] in varsAndTypesList)
      resultShow =
        if outcome.result?
        then outcome.result.elements()[0] ? '(empty)'  # FIXME: display all elements
        else outcome.error
      line.push(new ViewCell(resultShow))
      grid.push(line)
    data = ((cell.value for cell in row) for row in grid)
    @hot.loadData(data)
  destroy: () ->
    @hot.destroy()

updateTracingView = (template) ->
  formulaInfo = newFormulaInfo.get()
  columnId = changeColumnArgs.get()[0].columnId
  # Tracing can be slow, so do it only on first demand.  (Longer term, we should
  # optimize it!)
  unless formulaInfo.haveTraced
    traceColumnFormula(formulaInfo.root.formula, columnId)
    formulaInfo.haveTraced = true
  unless tracingView?
    tracingView = new TracingView(template.find('#TracingView'))
  tracingView.show(formulaInfo.selectedBand.node.formula)

isExpanded = () ->
  newFormulaInfo.get()?.selectedBand?

changeColumnSubmit = (template) ->
  try
    if template.data.isObject
      # Set the reference display formula.
      referenceDisplayStr = newReferenceDisplayStr.get()
      if referenceDisplayStr?
        if referenceDisplayStr == ''
          referenceDisplay = null   # revert to default
        else
          try
            referenceDisplay = parseFormula(template.data.columnId, referenceDisplayStr)
          catch e
            unless e instanceof FormulaValidationError
              throw e
            alert('Failed to parse reference display formula: ' + e.message)
            return false
          # Canonicalize the string in the field, otherwise the field might stay
          # yellow after successful submission.
          referenceDisplayStr = stringifyFormula(template.data.columnId, referenceDisplay)
          template.find('input[name=referenceDisplay]').value = referenceDisplayStr
          newReferenceDisplayStr.set(referenceDisplayStr)
        Meteor.call('changeColumnReferenceDisplay', $$,
                    template.data.columnId,
                    referenceDisplay,
                    standardServerCallback)
    else
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
      if displayStr?
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
          displayStr = stringifyFormula(getColumn(template.data.columnId).type, display)
          template.find('input[name=display]').value = displayStr
          newDisplayStr.set(displayStr)
        Meteor.call('changeColumnDisplay', $$,
                    template.data.columnId,
                    display,
                    standardServerCallback)
  catch e
    console.error e

Template.changeColumn.events
  'input .display': (event, template) ->
    newDisplayStr.set(event.target.value) #template.find('input[name=display]').value)
  'input .referenceDisplay': (event, template) ->
    newReferenceDisplayStr.set(event.target.value)
  'submit form': (event, template) ->
    changeColumnSubmit(template)
    false # prevent refresh
  'click [type=reset]': (event, template) ->
    orig = origFormulaStrForColumnId(@columnId)
    newFormulaStr.set(orig)
    template.codeMirror?.getDoc().setValue(orig)
    orig = origDisplayStrForColumnId(@columnId)
    newDisplayStr.set(orig)
    template.find('input[name=display]')?.value = orig
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
  'click .formulaBand': (event, template) ->
    # Update selection.
    formulaInfo = newFormulaInfo.get()
    formulaInfo.selectedBand?.selected = false
    formulaInfo.selectedBand = this
    @selected = true
    newFormulaInfo.set(formulaInfo)  # Trigger reactive dependents

    # Make sure tracing area has become visible, if necessary.
    Tracker.afterFlush(() -> updateTracingView(template))

# Needed for the formula div to get added during the "Create formula" handler,
# rather than sometime later when we get the update from the server.
Meteor.methods({
  changeColumnFormula: (cc, columnId, formula) ->
    Columns.update(columnId, {$set: {formula: formula}})
})



exported {ActionBar: {fullTextToShow, isLoading, addStateCellArgs, changeColumnArgs, isExpanded}, standardServerCallback, andThen}
