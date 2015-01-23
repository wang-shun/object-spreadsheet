
Columns = new Mongo.Collection(COLUMN_COLLECTION)
Cells = new Mongo.Collection(CELLS_COLLECTION)


class ColumnBinRel
  constructor: (@columnId) ->

  cells: ->
    families = Cells.find({column: @columnId}).fetch()
    famcells = (family) -> ([family.key, v] for v in family.values)
    [].concat((famcells x for x in families)...)

  add: (key, value, callback=->) ->
    if Meteor.isServer
      Cells.upsert {column: @columnId, key}, {$addToSet: {values: value}}
      callback()
    else
      Meteor.call 'ColumnBinRel_add', @columnId, key, value, callback

  remove: (key, value, callback=->) ->
    if Meteor.isServer
      Cells.update {column: @columnId, key}, {$pull: {values: value}}
      callback()
    else
      Meteor.call 'ColumnBinRel_remove', @columnId, key, value, callback

  lookup: (keys) ->
    # @param keys: an EJSONKeyedSet or TypedSet
    # @return a TypedSet with matching values from column, {x.column | x in keys}
    if keys instanceof TypedSet
      # TODO check type
      keys = keys.set
    cells = @cells()
    c = Columns.findOne(@columnId)
    values = new EJSONKeyedSet(cell[1] for cell in cells when keys.has cell[0])
    new TypedSet(c.type, values)


if Meteor.isServer
  Meteor.methods
    ColumnBinRel_add: (columnId, key, value) ->
      new ColumnBinRel(columnId).add(key, value)
    ColumnBinRel_remove: (columnId, key, value) ->
      new ColumnBinRel(columnId).remove(key, value)


exported = (d) ->
  for k,v of d
    @[k] = v

exported {Columns, Cells, ColumnBinRel}
