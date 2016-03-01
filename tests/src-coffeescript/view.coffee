

class @View
  constructor: (@id) ->

  def: ->
    if @id?
      Views.findOne(@id) || {layout: new Tree(rootColumnId)}
    else
      {layout: View.rootLayout()}

  addColumn: (columnId, own=false) ->
    def = @def()
    parentId = Columns.findOne(columnId)?.parent
    if parentId?
      layoutTree = def.layout
      layoutSubtree = layoutTree.find(parentId)
      if layoutSubtree?
        layoutSubtree.subtrees.push(new Tree(columnId))
        Views.upsert(@id, def)
      if own
        Columns.update(columnId, {$set: {view: @id}})
    return

  removeColumn: (columnId) ->
    def = @def()
    def.layout = def.layout.filter((x) -> x != columnId)
    Views.update(@id, def)
    return

  reorderColumn: (columnId, newIndex) ->
    def = @def()
    parentId = Columns.findOne(columnId)?.parent
    if parentId?
      layoutTree = def.layout
      layoutSubtreeParent = layoutTree.find(parentId)
      layoutSubtreeChild = layoutTree.find(columnId)
      if layoutSubtreeParent? && layoutSubtreeChild?
        layoutSubtreeParent.subtrees = (x for x in layoutSubtreeParent.subtrees when x.root != columnId)
        layoutSubtreeParent.subtrees.splice(newIndex, 0, layoutSubtreeChild)
        Views.update(@id, {$set: {layout: layoutTree}})
        # Cannot use upsert or update(@id, def) if calling from client
        # "update failed: Access denied. Upserts not allowed in a restricted collection."
    return

  @rootLayout: -> @drillDown(rootColumnId).filter (x) => !@ownerOf(x)?

  @drillDown: (startingColumnId) ->
    children = Columns.findOne(startingColumnId)?.children || []
    new Tree(startingColumnId, (@drillDown child for child in children))

  @ownerOf: (columnId) ->
    Columns.findOne(columnId)?.view

  @removeColumnFromAll: (columnId) ->
    Views.find().forEach (view) ->
      if view.layout.find(columnId)?
        new View(view._id).removeColumn(columnId)
      return
    return


