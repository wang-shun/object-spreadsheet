fullTextToShow = new ReactiveVar(null)
isLoading = new ReactiveVar(true)

Template.actionBar.helpers
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
  formula && stringifyFormula(col.parent, formula)

origFormulaStr = new ReactiveVar(null)
Tracker.autorun(() ->
  cca = changeColumnArgs.get()[0]
  origFormulaStr.set(if cca? then origFormulaStrForData(cca) else null)
  )
newFormulaStr = new ReactiveVar(null)
newFormulaInfo = new ReactiveVar(null)

isFormulaDebuggerOpen = new ReactiveVar(false)

tracingView = null

Template.changeColumn.rendered = () ->
  # XXX What if there are unsaved changes when the formula changes externally?
  @autorun(() ->
    newFormulaStr.set(origFormulaStr.get())
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
    )
  @autorun(() =>
    shouldShowFormulaBar = newFormulaStr.get()?
    if shouldShowFormulaBar && !@codeMirror?
      # Have to wait for the template to re-render with the new div.
      # afterFlush will become unmaintainable if we push it much further, but
      # works for now and is easier than trying to figure out the referencing
      # for a child template.
      Tracker.afterFlush(() => changeColumnInitFormulaBar(this))
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
    )

Template.changeColumn.destroyed = () ->
  # Try to avoid holding on to data that's no longer relevant.
  # XXX: Should we rather define the reactive vars on the template instance?
  # Then we'd need more Template.instance() from the helpers.
  isFormulaDebuggerOpen.set(false)
  tracingView?.destroy()
  tracingView = null
  newFormulaInfo.set(null)
  newFormulaStr.set(null)

# Scanning for all possible reference types is slow enough to make the selection
# feel laggy, so cache the menu and reuse it.
typeMenuCommonItems = new ReactiveVar([])
Relsheets.onOpen(() ->
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
    scan(rootColumnId)

    items = []
    items.push(new HtmlOptgroup('Basic types',
                                (new HtmlOption(t, t) for t in MAIN_PRIMITIVE_TYPES)))
    items.push(new HtmlOptgroup('Reference to:', refItems))
    typeMenuCommonItems.set(items)
    ))

Template.changeColumn.helpers
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
      # Note: Not info.formula, it might not have a .type field.
      inferredTypeDesc = if info?.root? then stringifyType(info.root.formula.type) else 'error'
      items.push(new HtmlOption('auto', "auto (#{inferredTypeDesc})"))
    items.push(typeMenuCommonItems.get()...)
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
      Enter: (cm) -> template.find('.saveFormula').click()
      Esc: (cm) -> template.find('.revertFormula').click()
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
      updateFormulaView(template))
    ]
  template.codeMirror.on('beforeChange', (cm, change) ->
    if change.update?
      newtext = change.text.join('').replace(/\n/g, '')
      change.update(null, null, [newtext])
    # Otherwise, change is coming from undo or redo; hope it's OK.
    )
  template.codeMirror.on('changes', (cm) ->
    newFormulaStr.set(template.codeMirrorDoc.getValue()))

updateFormulaView = (template) ->
  tracingView?.destroy()
  tracingView = null
  formulaStr = newFormulaStr.get()
  formulaInfo = {}
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
    newFormulaInfo.set(formulaInfo)
    return
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
  layoutSubtree(formulaInfo.root)
  formulaInfo.selectedBand = null
  formulaInfo.haveTraced = false
  newFormulaInfo.set(formulaInfo)

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
  tracingView.show(formulaInfo.selectedBand.node)

hasUnsavedData = () ->
  newFormulaStr.get() != origFormulaStr.get()

isExpanded = () ->
  isFormulaDebuggerOpen.get()

Template.changeColumn.events
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
    if newFormula? && Cells.find({column: @columnId, values: {$not: {$size: 0}}}).count() &&
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
  'change #changeColumn-type': (event, template) ->
    newSpecifiedType = getValueOfSelectedOption(template, '#changeColumn-type')
    if newSpecifiedType == 'auto'
      newSpecifiedType = null
    Meteor.call('changeColumnSpecifiedType', $$,
                @columnId,
                newSpecifiedType,
                standardServerCallback)
  'change #changeColumn-referenceDisplayColumn': (event, template) ->
    newReferenceDisplayColumn = getValueOfSelectedOption(template, '#changeColumn-referenceDisplayColumn')
    if newReferenceDisplayColumn == 'auto'
      newReferenceDisplayColumn = null
    Meteor.call('changeColumnReferenceDisplayColumn', $$,
                @columnId,
                newReferenceDisplayColumn,
                standardServerCallback)
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
  'click .revertFormula': (event, template) ->
    newFormulaStr.set(origFormulaStr.get())
  'click .formulaDebuggerToggle': (event, template) ->
    isFormulaDebuggerOpen.set(!isFormulaDebuggerOpen.get())
  'click .formulaBand': (event, template) ->
    # Update selection.
    formulaInfo = newFormulaInfo.get()
    formulaInfo.selectedBand?.selected = false
    formulaInfo.selectedBand = this
    @selected = true
    newFormulaInfo.set(formulaInfo)  # Trigger reactive dependents

    # XXX Might be nice to make this an autorun.
    updateTracingView(template)

# Needed for the formula div to get added during the "Create formula" handler,
# rather than sometime later when we get the update from the server.
Meteor.methods({
  changeColumnFormula: (cc, columnId, formula) ->
    Columns.update(columnId, {$set: {formula: formula}})
})



exported {ActionBar: {fullTextToShow, isLoading, changeColumnArgs, isExpanded, hasUnsavedData}}
