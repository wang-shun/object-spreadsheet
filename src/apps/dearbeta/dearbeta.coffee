
if Meteor.isClient
  Router.route "/:sheet/apps", -> @render "DearBeta", data: {sheet: @params.sheet}


  Template.DearBeta.created = ->
    sheet = @data?.sheet
    Tablespace.default = Tablespace.get sheet
    Meteor.call 'open', $$

  Template.DearBeta.helpers
    cells: ->
      Cells.find()
    files: ->
      t = View.rootLayout()
      obj = readObj(t, [])
      obj.File

  Template.DearBeta.events
    "click .Request .up": -> $$.call "requestUp", @Request.qFamilyId
    "click .Request .down": -> $$.call "requestDown", @Request[0]?.qCellId
    "click .Hint .up": -> $$.call "hintUp", @Vote.qFamilyId
    "click .Hint .down": -> $$.call "hintDown", @Vote[0]?.qCellId
    "click .Hint .del": -> $$.call "hintDel", @qCellId
    "submit form": (event) ->
      $$.call "hintAdd", @Hint.qFamilyId, event.target.text.value, ->
        event.target.reset()
      false


if Meteor.isServer
  
  Meteor.methods
    requestUp: (cc, qFamilyId) -> cc.runTransaction ->
      new ColumnBinRel(qFamilyId.columnId).add(qFamilyId.cellId, Random.id())
    requestDown: (cc, qCellId) -> cc.runTransaction ->
      if qCellId?
        new ColumnBinRel(qCellId.columnId).remove(qCellId.cellId)
    hintUp: (cc, qFamilyId) -> cc.runTransaction ->
      new ColumnBinRel(qFamilyId.columnId).add(qFamilyId.cellId, Random.id())
    hintDown: (cc, qCellId) -> cc.runTransaction ->
      if qCellId?
        new ColumnBinRel(qCellId.columnId).remove(qCellId.cellId)
    hintAdd: (cc, qFamilyId, text) -> cc.runTransaction ->
      tok = Random.id()
      new ColumnBinRel(qFamilyId.columnId).add(qFamilyId.cellId, tok)
      new ColumnBinRel(parseColumnRef("File:Node:Time:Hint:body")[0])
        .add(cellIdChild(qFamilyId.cellId, tok), text)
    hintDel: (cc, qCellId) -> cc.runTransaction ->
      new ColumnBinRel(qCellId.columnId).remove(qCellId.cellId)
        
  procedures =
    requestUp:
      params: [['at', 'File:Node:Time']]
      body: '''new at.Request
'''
    requestDown:
      params: [['at', 'File:Node:Time']]
      body: '''delete oneOf(at.Request)'''
    hintUp:
      params: [['at', 'File:Node:Time:Hint']]
      body: '''new at.Vote'''
    hintDown:
      params: [['at', 'File:Node:Time:Hint']]
      body: '''delete oneOf(at.Vote)'''
    hintAdd:
      params: [['at', 'File:Node:Time'], ['text', '_string']]
      body: '''let h = create at.Hint
               h.body = text'''
    hintDel:
      params: [['at', 'File:Node:Time:Hint']]
      body: '''delete at'''
  
  @gogogo = ->
    for name of procedures
      proc = procedures[name]
      parseProcedure(proc.params, proc.body)
  
readObj = (t, rootCellId, keyField=undefined) ->
  obj = {qCellId: {columnId: t.root, cellId: rootCellId}}
  if keyField?
    obj[keyField] = cellIdLastStep(rootCellId)
  for x in t.subtrees
    c = Columns.findOne(x.root)
    if c?
      vals = new ColumnBinRel(x.root).lookup(set([rootCellId])).set.elements()
      if c.objectName?
        fam = (readObj(x, cellIdChild(rootCellId, v), c.fieldName) for v in vals)
        fam.qFamilyId = {columnId: x.root, cellId: rootCellId}
        obj[c.objectName] = fam
      else if c.fieldName?
        obj[c.fieldName] = vals
  
  obj