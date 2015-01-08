class FieldInfo

  constructor: (@name, @singular, @unique) ->


class Table extends Array

  constructor: (@fieldInfos, iterable) ->
    @push x for x in iterable
    p = {}
    for x in @fieldInfos
      do (x) -> p[x.name] = {get: -> @proj x.name}
    Object.defineProperties @, p

  colidx: (colname) ->
    (idx for fi,idx in @fieldInfos when fi.name == colname)[0]

  proj: (colname) ->
    idx = @colidx colname
    new BinRel(([i,row[idx]] for row,i in @),
               @fieldInfos[idx].singular, @fieldInfos[idx].unique)

  domain: -> i for _,i in @
  id: -> new BinRel(([i,i] for _,i in @), true, true)


class BinRel extends Array

  # "Singular" means the schema requires that for each x,
  # there's at most one y such that (x,y) is in the relation.
  # "Unique": other way around.  Better terms welcomed.
  constructor: (iterable, @singular, @unique) ->
    @push x for x in iterable

  proj: (colidx) -> (x[colidx] for x in @)

  domain: -> @proj 0
  id: -> new BinRel([x,x] for x in @domain, true, true)

  xpose: -> new BinRel([y,x] for [x,y] in @, @unique, @singular)

  comp: (that) ->
    prod = []
    prod.push [r,s] for r in @ for s in that
    new BinRel(([r[0],s[1]] for [r,s] in prod when r[1]==s[0]),
               @singular && that.singular, @unique && that.unique)

  lookup: (key) ->
    r[1] for r in @ when r[0] == key

  grouping: ->
    runs @proj 1

  runs = (arr) ->
    prev = [undefined, -1]
    strip = (1 for x in arr)
    for i in [strip.length-2..0] by -1
      if arr[i] == arr[i+1]
        strip[i] = strip[i+1] + 1
        strip[i+1] = 0
    strip


class ViewField
  constructor: (@relation, @subsection) ->


class ViewSection

  constructor: (firstColumnName, @fields) ->
    # Currently, we always have the original value in the first column.
    @columnNames = [firstColumnName]
    @leftEdgeSingular = true
    @rightEdgeSingular = true
    # field index -> bool (have a separator column before this field)
    @haveSeparatorColBefore = []
    for field in @fields
      nextLeftEdgeSingular =
        field.relation.singular && field.subsection.leftEdgeSingular
      haveSep = (!@rightEdgeSingular && !nextLeftEdgeSingular)
      @haveSeparatorColBefore.push(haveSep)
      if haveSep
        @columnNames.push('')
      # TODO: Make the hierarchy clear in the column names?
      @columnNames.push(field.subsection.columnNames...)
      @rightEdgeSingular =
        field.relation.singular && field.subsection.rightEdgeSingular

  prerenderVlist: (values) ->
    hlists = (@prerenderHlist(value) for value in values)
    minHeight = 0
    for hlist in hlists
      minHeight += hlist.minHeight
    new ViewVlist(minHeight, hlists)

  prerenderHlist: (value) ->
    minHeight = 1
    items = []
    for field in @fields
      fieldValues = field.relation.lookup(value)
      if field.relation.singular
        item = field.subsection.prerenderHlist(fieldValues[0])
        minHeight = Math.max(minHeight, item.minHeight)
      else
        item = field.subsection.prerenderVlist(fieldValues)
        # Ensure that a plural field with only one value is followed by at least
        # one blank row so the user can tell it is plural.  We currently don't
        # provide a visual distinction between empty singular and plural fields.
        minHeight = Math.max(minHeight,
                             item.minHeight + (fieldValues.length == 1))
      items.push(item)
    new ViewHlist(minHeight, value, items)

  renderVlist: (vlist, height) ->
    grid = []
    for hlist in vlist.hlists
      grid.push(@renderHlist(hlist, hlist.minHeight)...)
    # Add blank cell at bottom
    origHeight = grid.length
    for row in [origHeight..height-1] by 1
      grid.push(new ViewCell('', 1, 1) for col in [0..@columnNames.length-1] by 1)
    if origHeight < height
      grid[origHeight][0].rowspan = height - origHeight
      grid[origHeight][0].colspan = @columnNames.length
    grid

  renderHlist: (hlist, height) ->
    # Value
    grid = [].concat(
      [[new ViewCell(hlist.value, height, 1)]],
      [new ViewCell('', 1, 1)] for row in [1..height-1] by 1
    )
    # Fields
    for field, i in @fields
      if @haveSeparatorColBefore[i]
        grid[0].push(new ViewCell('', height, 1))
        for j in [1..height-1] by 1
          grid[j].push(new ViewCell('', 1, 1))
      fieldGrid =
        if field.relation.singular
        then field.subsection.renderHlist(hlist.items[i], height)
        else field.subsection.renderVlist(hlist.items[i], height)
      for j in [0..height-1] by 1
        grid[j].push(fieldGrid[j]...)
    grid

class ViewCell
  constructor: (@value, @rowspan, @colspan) ->

class ViewVlist
  constructor: (@minHeight, @hlists) ->

class ViewHlist
  # Items contains one item for each field: an hlist for a singular field or a
  # vlist for a plural field.
  constructor: (@minHeight, @value, @items) ->

class View
  constructor: (@domain, @mainSection) ->

  hotConfig: ->
    vlist = @mainSection.prerenderVlist(@domain)
    grid = @mainSection.renderVlist(vlist, vlist.minHeight)
    d = {
      data: ((cell.value for cell in row) for row in grid),
      colHeaders: @mainSection.columnNames,
      # Separator columns are 8 pixels wide.  Others use default width.
      colWidths: (for n in @mainSection.columnNames
                    if n then undefined else 8),
      autoColumnSize: true,
      mergeCells: [].concat((
        for row,i in grid
          for cell,j in row when cell.rowspan != 1 || cell.colspan != 1
            {row: i, col: j, rowspan: cell.rowspan, colspan: cell.colspan}
        )...)
    }
    d


Person = new Table [new FieldInfo("name", true, true)], [
  ["Daniel Jackson"]
  ["Jonathan Edwards"]
  ["Hefty"]
  ["Brainy"]
  ["Clumsy"]
  ["Greedy"]
  ["Jokey"]
  ["Chef"]
  ["Vanity"]
]

Teacher_Student = new BinRel [
  [0,2], [0,3], [0,4]
  [1,5], [1,6], [1,7], [1,8]
], false, false

# Meaningless data that serves to demonstrate a separator column.
Teacher_Slot = new BinRel [
  [0, '1-2'], [0, '2-3']
  [1, '3-4'], [1, '4-5']
], false, false

v = new View(
  Person.domain(),
  new ViewSection("ID", [
    new ViewField(Person.name, new ViewSection("teacher", [])),
    new ViewField(Teacher_Student.comp(Person.name), new ViewSection("student", []))
    new ViewField(Teacher_Slot, new ViewSection("slot", []))
  ]))

$ () ->
  x = $ '#Person'
  new Handsontable x[0], v.hotConfig()
  #x.append ($ "<p>") .text (table.teacher.grouping())
