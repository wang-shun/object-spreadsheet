
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
    "click button.up": ->
      StateEdit.addCell @Request.qFamilyId, "*"
    "click button.down": ->
      if (h = @Request[0])?
        StateEdit.removeCell h.qCellId

    
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