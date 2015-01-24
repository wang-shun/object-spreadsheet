
Columns = new Mongo.Collection(COLUMN_COLLECTION)
Cells = new Mongo.Collection(CELLS_COLLECTION)


class ColumnBinRel
  constructor: (@columnId) ->

  cells: ->
    families = Cells.find({column: @columnId}).fetch()
    famcells = (family) -> ([family.key, v] for v in family.values)
    [].concat((famcells x for x in families)...)

  cellset: ->
    c = Columns.findOne(@columnId)
    new TypedSet([c.parent, c.type], set(@cells()))

  add: (key, value, callback=->) ->
    if Meteor.isServer
      Cells.upsert {column: @columnId, key}, {$addToSet: {values: value}}
      Meteor.call 'notifyChange', callback
    else
      Meteor.call 'ColumnBinRel_add', @columnId, key, value, callback

  remove: (key, value, callback=->) ->
    if Meteor.isServer
      Cells.update {column: @columnId, key}, {$pull: {values: value}}
      Meteor.call 'notifyChange', callback
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
    values = set(cell[1] for cell in cells when keys.has cell[0])
    new TypedSet(c.type, values)


class PairsBinRel
  constructor: (@pairs, @domainType='_any', @rangeType='_any') ->

  cells: -> @pairs

  cellset: -> new TypedSet([@domainType, @rangeType], set(@pairs))

  lookup: (keys) ->
    if keys instanceof TypedSet
      # TODO check type
      keys = keys.set
    values = set(cell[1] for cell in @pairs when keys.has cell[0])
    new TypedSet(@rangeType, values)

  transpose: ->
    sriap = ([x[1], x[0]] for x in @pairs)
    new PairsBinRel(sriap, @rangeType, @domainType)


if Meteor.isServer
  Meteor.methods
    ColumnBinRel_add: (columnId, key, value) ->
      new ColumnBinRel(columnId).add(key, value)
    ColumnBinRel_remove: (columnId, key, value) ->
      new ColumnBinRel(columnId).remove(key, value)


exported = (d) ->
  for k,v of d
    @[k] = v

exported {Columns, Cells, ColumnBinRel, PairsBinRel}
