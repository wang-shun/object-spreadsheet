

class View
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

  removeColumn: (columnId) ->
    def = @def()
    def.layout = def.layout.filter((x) -> x != columnId)
    Views.update(@id, def)

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



exported {View}
