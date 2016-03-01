fullTextToShow = new ReactiveVar(null)
isLoading = new ReactiveVar(true)

Template['actionBar'].helpers
  loading: -> isLoading.get()
  fullTextToShow: -> fullTextToShow.get()
  changeColumnArgs: -> changeColumnArgs.get()

#
# Template changeColumn
#
changeColumnArgs = new ReactiveVar([], EJSON.equals)

NESTED_UNDERLINING_PX_PER_LEVEL = 4
NESTED_UNDERLINING_MAX_DEPTH = 5

# We mainly care that this doesn't crash.
origFormulaStrForData = (data) ->
  if data.onObjectHeader then return null
  col = getColumn(data.columnId)
  formula = col?.formula
  if !formula?
    null
  else if EJSON.equals(formula, DUMMY_FORMULA)
    ''
  else
    stringifyFormula(col.parent, formula)

origFormulaStr = new ReactiveVar(null)
Tracker.autorun(() ->
  cca = changeColumnArgs.get()[0]
  origFormulaStr.set(if cca? then origFormulaStrForData(cca) else null)
  return
  )
newFormulaStr = new ReactiveVar(null)
newFormulaInfo = new ReactiveVar(null)

isFormulaDebuggerOpen = new ReactiveVar(false)

tracingView = null

Template['changeColumn'].rendered = () ->
  # XXX What if there are unsaved changes when the formula changes externally?
  @autorun(() ->
    newFormulaStr.set(origFormulaStr.get())
    return
    )
  @autorun(() ->
    unless isFormulaDebuggerOpen.get()
      info = newFormulaInfo.get()
      if info?.selectedBand?
        info.selectedBand.selected = false
        info.selectedBand = null
        # Retriggers this autorun, but it will do nothing the second time.
        newFormulaInfo.set(info)
      tracingView?.destroy()
      tracingView = null
    return
    )
  @autorun(() =>
    shouldShowFormulaBar = newFormulaStr.get()?
    if shouldShowFormulaBar && !@codeMirror?
      # Have to wait for the template to re-render with the new div.
      # afterFlush will become unmaintainable if we push it much further, but
      # works for now and is easier than trying to figure out the referencing
      # for a child template.
      Tracker.afterFlush(() => changeColumnInitFormulaBar(this); return)
    else if !shouldShowFormulaBar && @codeMirror?
      # TODO: Consider allowing the action bar to remain expanded when the user
      # switches columns.  But if we make the toggle button always visible, it
      # will be less clear that it is related to the formula.
      isFormulaDebuggerOpen.set(false)
      for c in @formulaBarComputations
        c.stop()
      @formulaBarComputations = null
      newFormulaInfo.set(null)
      # XXX Do we need to tear down the CodeMirror somehow?
      @codeMirror = null
    return
    )
  return

Template['changeColumn'].destroyed = () ->
  # Try to avoid holding on to data that's no longer relevant.
  # XXX: Should we rather define the reactive vars on the template instance?
  # Then we'd need more Template.instance() from the helpers.
  isFormulaDebuggerOpen.set(false)
  tracingView?.destroy()
  tracingView = null
  newFormulaInfo.set(null)
  newFormulaStr.set(null)
  return

# Scanning for all possible reference types is slow enough to make the selection
# feel laggy, so cache the menu and reuse it.
typeMenuCommonItems = new ReactiveVar([])
RelsheetsClient.onOpen(() ->
  Tracker.autorun(() ->
    # Note: It's possible to create cycles in the "key + parent" relation on
    # object types.  This is a pointless thing to do but does not break our
    # tool; it's as if all of those reference types were merely empty.  So
    # don't try to prevent it for now.
    refItems = []
    scan = (colId) ->
      c = getColumn(colId)
      unless c?
        return  # Not ready?  What a pain.
      if colId != rootColumnId && c.isObject
        refItems.push(new HtmlOption(colId, stringifyType(colId)))
      for childId in c.children
        scan(childId)
      return
    scan(rootColumnId)

    items = []
    items.push(new HtmlOptgroup('Basic types',
                                (new HtmlOption(t, t) for t in MAIN_PRIMITIVE_TYPES)))
    items.push(new HtmlOptgroup('Reference to:', refItems))
    typeMenuCommonItems.set(items)
    return
    )
  return
  )

Template['changeColumn'].helpers
  #col: -> getColumn(@columnId)
  isFormulaModified: ->
    newFormulaStr.get() != origFormulaStr.get()
  canSave: ->
    # Looks like this can be called before the autorun that sets newFormulaInfo.  Grr.
    newFormulaStr.get() != origFormulaStr.get() && newFormulaInfo.get()?.formula?
  columnName: ->
    stringifyColumnRef([@columnId, !@onObjectHeader])
  keyColumnName: ->
    c = getColumn(@columnId)
    if @onObjectHeader && c.type != '_token' then c.fieldName else null
  typeMenu: ->
    col = getColumn(@columnId)
    items = []
    if col.formula?
      # Note: Inferred type should match c.type if c.specifiedType is null and
      # there are no unsaved changes to the formula.
      info = newFormulaInfo.get()
      inferredTypeDesc = if info?.formula?.type? then stringifyType(info.formula.type) else 'error'
      items.push(new HtmlOption('auto', "auto (#{inferredTypeDesc})"))
    for item in typeMenuCommonItems.get()
      items.push(item)
    new HtmlSelect(items, col.specifiedType ? 'auto')
  backendMenu: ->
    new HtmlSelect([
      new HtmlOption('state', 'editable'),
      new HtmlOption('computed', 'computed by formula'),
      ], if getColumn(@columnId).formula? then 'computed' else 'state')
  isComputed: ->
    getColumn(@columnId).formula?
  newFormulaInfo: ->
    newFormulaInfo.get()
  isFormulaDebuggerOpen: ->
    isFormulaDebuggerOpen.get()
  contextText: ->
    col = getColumn(@columnId)
    if col.isObject  # i.e., we are editing the formula of a key column
      objectNameWithFallback(getColumn(col.parent)) ? '(unnamed)'
    else null
  # Color-coding is much less useful with non-rainbow palettes.
  #contextColorIndex: ->
  #  col = getColumn(@columnId)
  #  if col.isObject
  #    colorIndexForDepth(columnDepth(col.parent))
  #  else null

  # Should only be called when onObjectHeader = true
  referenceDisplayColumnMenu: ->
    col = getColumn(@columnId)
    defaultColId = defaultReferenceDisplayColumn(col)
    defaultColDesc =
      if defaultColId?
        getColumn(defaultColId).fieldName ? 'unnamed'
      else
        'none'
    items = [new HtmlOption('auto', "Choose automatically (#{defaultColDesc})")]
    for displayColId in allowedReferenceDisplayColumns(col)
      displayCol = getColumn(displayColId)
      items.push(new HtmlOption(displayColId, displayCol.fieldName ? '(unnamed)'))
    new HtmlSelect(items, col.referenceDisplayColumn ? 'auto')

changeColumnInitFormulaBar = (template) ->
  formula = origFormulaStr.get()
  template.codeMirror = CodeMirror(template.find('#changeFormula-formula'), {
    value: ''  # filled in by autorun below
    extraKeys: {
      Enter: (cm) -> template.find('.saveFormula').click(); return
      Esc: (cm) -> template.find('.revertFormula').click(); return
    }
    })
  template.codeMirrorDoc = template.codeMirror.getDoc()
  template.formulaBarComputations = [
    template.autorun(() ->
      # http://stackoverflow.com/a/15256593
      height = template.codeMirror.defaultTextHeight() + 2 * 4
      if isFormulaDebuggerOpen.get()
        height += NESTED_UNDERLINING_PX_PER_LEVEL * NESTED_UNDERLINING_MAX_DEPTH
      template.codeMirror.setSize('100%', height)
      return
    ),
    template.autorun(() ->
      formulaStr = newFormulaStr.get()
      unless formulaStr?
        # When the formula is cleared, sometimes this runs before the autorun
        # that tears down the formula bar.  Grr, Meteor, how are we supposed to
        # avoid these problems in general?
        return
      # Avoid re-setting in response to user input, since this sends the cursor
      # back to the beginning.  Wish for a better two-way binding mechanism...
      if formulaStr != template.codeMirrorDoc.getValue()
        template.codeMirrorDoc.setValue(formulaStr)
      newFormulaInfo.set(generateFormulaInfo(template))
      return
    )]
  template.codeMirror.on('beforeChange', (cm, change) ->
    if change.update?
      newtext = change.text.join('').replace(/\n/g, '')
      change.update(null, null, [newtext])
    # Otherwise, change is coming from undo or redo; hope it's OK.
    return
    )
  template.codeMirror.on('changes', (cm) ->
    newFormulaStr.set(template.codeMirrorDoc.getValue())
    return
    )
  return

generateFormulaInfo = (template) ->
  tracingView?.destroy()
  tracingView = null
  formulaStr = newFormulaStr.get()
  formulaInfo = {}
  if formulaStr == ''
    formulaInfo.formula = DUMMY_FORMULA
    # Do not construct a subformula tree.
    return formulaInfo
  parentColumnId = getColumn(template.data.columnId).parent
  try
    formulaInfo.formula = parseFormula(parentColumnId, formulaStr)
    # Fill in vars expando field on all subformulas.  Obviously in the future
    # we want to be able to help troubleshoot ill-typed formulas, but we punt
    # all error tolerance until later rather than fight that complexity now.
    typecheckFormula(liteModel, new EJSONKeyedMap([['this', parentColumnId]]), formulaInfo.formula)
  catch e
    unless e instanceof FormulaValidationError
      throw e
    # TODO: More graceful error handling
    formulaInfo.error = e.message
    return formulaInfo
  formulaInfo.root = getSubformulaTree(formulaInfo.formula)
  formulaInfo.bands = []
  layoutSubtree = (node) ->
    # It looks silly to offer to debug a literal, though it's not harmful.  Open
    # to counterarguments. ~ Matt
    if node.formula[0] == 'lit'
      node.height = -1
      return
    node.ch1 = node.formula.loc.first_column
    node.ch2 = node.formula.loc.last_column
    node.height = 0
    for childInfo in node.children
      # loc missing for implicit "this" inserted by resolveNavigation; other cases?
      if childInfo.node.formula.loc?
        layoutSubtree(childInfo.node)
        isNavigationLhs = (node.formula[0] in ['up', 'down'] && childInfo.paramName == 'start')
        if isNavigationLhs
          node.ch1 = childInfo.node.ch2
        node.height = Math.max(node.height, childInfo.node.height + !isNavigationLhs)
    top = 4 + template.codeMirror.defaultTextHeight() + NESTED_UNDERLINING_PX_PER_LEVEL * node.height
    # Tweak for gaps in navigation chains.
    x1 = template.codeMirror.cursorCoords({line: 0, ch: node.ch1}, 'local').left
    x2 = template.codeMirror.cursorCoords({line: 0, ch: node.ch2}, 'local').left
    formulaInfo.bands.push({
      node: node
      selected: false
      left: x1
      width: x2 - x1
      top: top
      height: NESTED_UNDERLINING_PX_PER_LEVEL
      })
    return
  layoutSubtree(formulaInfo.root)
  formulaInfo.selectedBand = null
  formulaInfo.haveTraced = false
  return formulaInfo

class TracingView
  constructor: (domElement) ->
    # TODO: Add a bunch more settings?
    @grid = []
    @hot = new Handsontable(domElement, {
      readOnly: true
      readOnlyCellClassName: ''  # Not useful to dim everything.
      cells: (row, col, prop) =>
        cell = @grid[row]?[col]
        if !cell then return {}  # Would like to understand why this is needed...
        {
          className: cell.cssClasses.join(' ')
        }
      })
  show: (node) ->
    formula = node.formula
    formatOutcome = (outcome) ->
      if outcome.result?
        # TODO: Display in individual cells so we can support the
        # referent-related features.  Or do we like this better?
        # We could at least base the curly braces on
        # type-checking-level singular-ness once we have it.
        tsetToTextIgnoreErrors(outcome.result)
      else outcome.error
    # Exclude subformulas with additional bound variables, e.g., filter
    # predicate.  Currently, the only way to debug them is to select them
    # directly.  If we add support for a persistent set of test cases that are
    # heterogeneous in the local variables they define, we can probably remove
    # this restriction.
    #
    # Also throw out implicit "this" again. :/
    childrenToShow = (childInfo for childInfo in node.children when (
        childInfo.node.formula.loc? && EJSON.equals(childInfo.node.formula.vars, formula.vars)))
    # TODO: Enforce outside-to-inside order ourselves rather than relying on it
    # as a side effect of object iteration order and the way we typecheck
    # formulas.
    varsAndTypesList =
      (e for e in formula.vars.entries() when e[1] != rootColumnId)
    @grid = [[], []]
    typeCell = (type) -> new ViewCell(stringifyTypeForSheet(type), 1, 1, ['rsHeader', markDisplayClassesForType(type)...])
    for [name, type] in varsAndTypesList
      @grid[0].push(new ViewCell(name, 1, 1, ['rsHeader']))
      @grid[1].push(typeCell(type))
    for childInfo in childrenToShow
      @grid[0].push(new ViewCell(childInfo.paramName, 1, 1, ['rsHeader']))
      @grid[1].push(typeCell(childInfo.node.formula.type))
    @grid[0].push(new ViewCell('Result', 1, 1, ['rsHeader']))
    @grid[1].push(typeCell(formula.type))
    # XXX It would be cleaner for traceColumnFormula to ensure "traces" was
    # created at least as an empty list on all subformulas, but more work to
    # implement.
    for [varValues, outcome] in formula.traces?.entries()
      line =
        for [name, _] in varsAndTypesList
          val = varValues.get(name).elements()[0]
          new ViewCell(valueToTextIgnoreErrors(varValues.get(name).type, val))
      for childInfo in childrenToShow
        childOutcome = childInfo.node.formula.traces.get(varValues)
        # XXX Would we rather just evaluate cases that weren't originally reached?
        line.push(new ViewCell(if childOutcome? then formatOutcome(childOutcome) else '(not reached)'))
      line.push(new ViewCell(formatOutcome(outcome)))
      @grid.push(line)
    data = ((cell.value for cell in row) for row in @grid)
    @hot.loadData(data)
    return
  destroy: () ->
    @hot.destroy()
    return

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
  tracingView.show(formulaInfo.selectedBand.node)
  return

hasUnsavedData = () ->
  newFormulaStr.get() != origFormulaStr.get()

isExpanded = () ->
  isFormulaDebuggerOpen.get()

stateColumnHasValues = (columnId) ->
  Cells.find({column: columnId, values: {$not: {$size: 0}}}).count() > 0

Template['changeColumn'].events
  'change #changeColumn-backend': (event, template) ->
    newFormula =
      if getValueOfSelectedOption(template, '#changeColumn-backend') == 'computed'
        DUMMY_FORMULA
      else
        null
    col = getColumn(@columnId)
    # With these conditions (plus the fact that DUMMY_FORMULA returns empty sets),
    # one can toggle between an empty state column and DUMMY_FORMULA without warnings.
    # If we add the ability to undo this operation, we can probably remove the warnings
    # (except the numErroneousFamilies one, which Matt believes deserves more respect
    # in general).
    if newFormula? && stateColumnHasValues(@columnId) &&
        !window.confirm('This will delete all existing cells in the column.  Are you sure?')
      selectOptionWithValue(template, '#changeColumn-backend', 'state')
      return
    if !newFormula? && !EJSON.equals(col.formula, DUMMY_FORMULA)
      numErroneousFamilies = Cells.find({column: @columnId, error: {$exists: true}}).count()
      if col.typecheckError?
        msg = 'This will delete your formula.  '
      else
        msg = 'This will take a snapshot of the current computed data and delete your formula.'
        if numErroneousFamilies
          msg += "\n\n#{numErroneousFamilies} families are currently failing to evaluate; " +
               "they will become empty, and you will not be able to distinguish them from " +
               "families that were originally empty.\n\n"
        else
          msg += '  '
      msg += 'Are you sure?'
      if !window.confirm(msg)
        selectOptionWithValue(template, '#changeColumn-backend', 'computed')
        return
    # Server checks for "state column as child of formula column" error.
    # XXX: Disallow converting keyed objects to state?
    Meteor.call('changeColumnFormula', $$,
                @columnId,
                newFormula,
                standardServerCallback)
    return
  'change #changeColumn-type': (event, template) ->
    col = getColumn(@columnId)
    newSpecifiedType = getValueOfSelectedOption(template, '#changeColumn-type')
    if newSpecifiedType == 'auto'
      newSpecifiedType = null
    # If the new type is text, there is no risk of conversion failure, but I
    # think it's still valuable to explain what's happening.  Right?
    # ~ Matt 2015-12-04
    if (!col.formula? && stateColumnHasValues(@columnId) && !window.confirm(
          'This will attempt to reinterpret existing values as the new type.  ' +
          'Any values that cannot be converted will be deleted.  Proceed?'))
      selectOptionWithValue(template, '#changeColumn-type', col.specifiedType)
      return
    Meteor.call('changeColumnSpecifiedType', $$,
                @columnId,
                newSpecifiedType,
                standardServerCallback)
    return
  'change #changeColumn-referenceDisplayColumn': (event, template) ->
    newReferenceDisplayColumn = getValueOfSelectedOption(template, '#changeColumn-referenceDisplayColumn')
    if newReferenceDisplayColumn == 'auto'
      newReferenceDisplayColumn = null
    Meteor.call('changeColumnReferenceDisplayColumn', $$,
                @columnId,
                newReferenceDisplayColumn,
                standardServerCallback)
    return
  'click .saveFormula': (event, template) ->
    contextColumnId = getColumn(@columnId).parent
    # canSave ensures that this is defined.
    formula = newFormulaInfo.get().formula
    # Canonicalize the string in the field, otherwise the field might stay
    # yellow after successful submission.
    newFormulaStr.set(stringifyFormula(contextColumnId, formula))
    Meteor.call('changeColumnFormula', $$,
                @columnId,
                formula,
                standardServerCallback)
    return
  'click .revertFormula': (event, template) ->
    newFormulaStr.set(origFormulaStr.get())
    return
  'click .formulaDebuggerToggle': (event, template) ->
    isFormulaDebuggerOpen.set(!isFormulaDebuggerOpen.get())
    return
  'click .formulaBand': (event, template) ->
    # Update selection.
    formulaInfo = newFormulaInfo.get()
    formulaInfo.selectedBand?.selected = false
    formulaInfo.selectedBand = this
    @selected = true
    newFormulaInfo.set(formulaInfo)  # Trigger reactive dependents

    # XXX Might be nice to make this an autorun.
    updateTracingView(template)
    return

# Needed for the formula div to get added during the "Create formula" handler,
# rather than sometime later when we get the update from the server.
Meteor.methods({
  changeColumnFormula: (cc, columnId, formula) ->
    Columns.update(columnId, {$set: {formula: formula}})
    return
})



@ActionBar = {fullTextToShow, isLoading, changeColumnArgs, isExpanded, hasUnsavedData}
