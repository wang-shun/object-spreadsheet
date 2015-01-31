#COLUMN_COLLECTION = 'columns'
#CELLS_COLLECTION = 'cells'
# need them for publisher? maybe just use Columns._name, Cells._name?

Columns = new Mongo.Collection "columns"
Cells = new Mongo.Collection "cells"
Views = new Mongo.Collection "views"

# NOTE: This class treats erroneous families in formula columns as empty!  Do
# not use it if you care about error propagation.
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

  ## remove(key, oldValue) + add(key, newValue) in a single operation
  removeAdd: (key, oldValue, newValue, callback=->) ->
    if ! EJSON.equals(oldValue, newValue)
      if Meteor.isServer
        # This WOULD have been nice, but is not supported (Mongo ticket SERVER-1050)
        #Cells.upsert {column: @columnId, key}, {$pull: {values: oldValue}, $addToSet: {values: newValue}}
        Cells.update {column: @columnId, key}, {$pull: {values: oldValue}}
        Cells.upsert {column: @columnId, key}, {$addToSet: {values: newValue}}
        Meteor.call 'notifyChange', callback
      else
        Meteor.call 'ColumnBinRel_removeAdd', @columnId, key, oldValue, newValue, callback

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
    ColumnBinRel_removeAdd: (columnId, key, oldValue, newValue) ->
      new ColumnBinRel(columnId).removeAdd(key, oldValue, newValue)


exported = (d) ->
  for k,v of d
    @[k] = v

#exported {COLUMN_COLLECTION, CELLS_COLLECTION}
exported {Columns, Cells, Views, ColumnBinRel, PairsBinRel}
