
class Table extends Array

  constructor: (@header, iterable) ->
    @push x for x in iterable
    p = {}
    for x in @header
      do (x) -> p[x] = {get: -> @proj x}
    Object.defineProperties @, p

  colidx: (colname) -> @header.indexOf colname

  proj: (colname) ->
    idx = @colidx colname
    new BinRel([i,row[idx]] for row,i in @)

  domain: -> i for _,i in @
  id: -> new BinRel([i,i] for _,i in @)


class BinRel extends Array

  constructor: (iterable) ->
    @push x for x in iterable

  proj: (colidx) -> (x[colidx] for x in @)

  domain: -> @proj 0
  id: -> new BinRel([x,x] for x in @domain)

  xpose: -> new BinRel([y,x] for [x,y] in @)
  
  comp: (that) ->
    prod = []
    prod.push [r,s] for r in @ for s in that
    new BinRel([r[0],s[1]] for [r,s] in prod when r[1]==s[0])
  
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



class FlatView

  constructor: (@domain, @columns) ->

  toTable: ->
    resultSet = []
    for key in @domain
      subview = zipAll (col.lookup key for [_,col] in @columns)
      for x in subview
        resultSet.push [key].concat x
    new Table (["ID"].concat(h for [h,_] in @columns)), resultSet


Person = new Table ["name"], [
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
]

v = new FlatView Person.domain(), [
  ["teacher", Person.name],
  ["student", Teacher_Student.comp(Person.name)]
]

$ () ->
  x = $ '#Person'
  table = v.toTable()
  new Handsontable x[0],
    data: table
    colHeaders: table.header
  x.append ($ "<p>") .text (table.teacher.grouping())
