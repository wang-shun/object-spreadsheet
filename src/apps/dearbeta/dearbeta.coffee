
if Meteor.isClient
  Router.route "/:sheet/apps", -> @render "DearBeta", data: {sheet: @params.sheet}

  # C.f. standardServerCallback, andThen in prototype.coffee.
  executeCannedTransaction = (name, argsObj, callback) ->
    $$.call('executeCannedTransaction', name, argsObj,
            (error, result) -> if error? then alert(error.message) else callback?(result))

  Template.DearBeta.created = ->
    sheet = @data?.sheet
    Tablespace.default = Tablespace.get sheet
    Meteor.call 'defineDearbetaProcedures', $$

  Template.DearBeta.helpers
    cells: ->
      Cells.find()
    files: ->
      t = View.rootLayout()
      obj = readObj(t, [])
      obj.File

  Template.DearBeta.events
    "click .Request .up": ->
      executeCannedTransaction("requestUp", {at: [@Request.qFamilyId.cellId]})
    "click .Request .down": ->
      executeCannedTransaction("requestDown", {at: [@qCellId.cellId]})
    "click .Hint .up": ->
      executeCannedTransaction("hintUp", {at: [@Vote.qFamilyId.cellId]})
    "click .Hint .down": ->
      executeCannedTransaction("hintDown", {at: [@qCellId.cellId]})
    "click .Hint .del": ->
      executeCannedTransaction("hintDel", {at: [@qCellId.cellId]})
    "submit form": (event) ->
      executeCannedTransaction(
        "hintAdd",
        {at: [@Hint.qFamilyId.cellId], text: [event.target.text.value]},
        () -> event.target.reset())
      false


if Meteor.isServer
  
  procedures =
    requestUp:
      params: [['at', 'File:Node:Time']]
      body: '''new at.Request'''
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
      body: '''let h = new at.Hint
               h.body := text'''
    hintDel:
      params: [['at', 'File:Node:Time:Hint']]
      body: '''delete at'''
  
  Meteor.methods
    defineDearbetaProcedures: (cc) ->
      cc.run ->
        # This may run multiple times; it should overwrite and not cause any problems.
        try
          for name, proc of procedures
            @model.cannedTransactions.set(
              name, parseCannedTransaction(proc.params, proc.body))
        catch e
          # Incompatible schema change?
          console.log("Failed to define dearbeta sample procedure #{name}:", e.stack)
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