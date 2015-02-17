@loadSampleData = (model) ->
  # Sample schema and data in a more human-friendly hierarchical format.

  sampleSchema = [
    {
    type: '_token'
    cellName: 'Person'
    children: [
      {
      name: 'name'
      type: '_string'
      # TODO: Required, singleton; probably unique but maybe not in schema
      }
      {
      type: '_unit'
      cellName: 'Student'
      # No need to constrain singleton.
      children: [
        name: 'parent'
        type: 'Person'
        # There can be more than one parent, but there can be only one meeting per
        # enrollment, which we imagine several of the parents may attend if they
        # believe it is necessary.
      ]
      }
      # We don't flag parents explicitly.  A person is a parent by virtue of being
      # the parent of some student.
      {
      type: '_unit'
      cellName: 'Teacher'
      children: [
        {
        type: '_token'
        cellName: 'Slot'
        children: [
          {
          # We don't normally expect the time of an existing slot to change, but
          # I'm now thinking it's wiser not to try to enforce that by making the
          # time a direct child of Teacher when it has no direct meaning in the
          # context of the Teacher.  Such decisions won't always be clear. ~ Matt
          name: 'time'
          # TODO: Change to _datetime once supported.  As long as we are using
          # strings as placeholder values, set this to _string so editing
          # behaves sensibly.
          type: '_string' # TODO: define format
          }
        ]
        }
      ]
      }
    ]
    }
    {
    type: '_token'
    cellName: 'Class'
    children: [
      {
      name: 'code'
      type: '_string'
      # TODO: Required, singleton, unique
      }
      {
      name: 'name'
      type: '_string'
      # TODO: Required, singleton, unique (assuming department is sane)
      }
      {
      type: '_token'
      cellName: 'Section'
      children: [
        {
        name: 'teacher'
        type: 'Person:Teacher'
        # TODO: Required, singleton
        }
        {
        # There's some doubt in my mind whether the enrollment should be thought
        # of as belonging to the section.  We might want to associate other data
        # (e.g., grades) with it that is as important to the student as it is to
        # the section.  But for now, this is useful as an example of having both
        # a name and a cellName. ~ Matt
        name: 'student'
        type: 'Person:Student'
        cellName: 'Enrollment'
        }
      ]
      }
    ]
    }
    {
    type: '_token'
    cellName: 'Meeting'
    children: [
      {
      name: 'enrollment'
      type: 'Class:Section:Enrollment'
      # TODO: Required, singleton, unique
      }
      {
      name: 'slot'
      type: 'Person:Teacher:Slot'
      # TODO: Required, singleton, unique
      }
      # TODO: Constraint slot.Teacher == enrollment.Teacher
    ]
    }
  ]

  # Shorthands:

  # Simple value(s)
  V = () -> ([val, {}] for val in arguments)

  # Type _unit
  U = (cell) -> [['X', cell]]

  # Type _token: successive integer tokens for now.
  T = (cellList) -> ([i.toString(), cell] for cell, i in cellList)

  I = () ->
    for x in arguments
      if typeof x == 'number' then x.toString() else x

  # _mark is used only to refer to a cell within this input format.  IDs will be
  # assigned by the loading code.
  sampleData = {
    Person: T([
      {
      name: V('Daniel Jackson')
      Teacher: U({
        Slot: T([
          {time: V('2014-12-16 13:00')}
          {time: V('2014-12-16 13:15')}
          {time: V('2014-12-16 13:30')}
          {time: V('2014-12-16 13:45')}
        ])
      })
      }
      {
      name: V('Jonathan Edwards')
      Teacher: U({
        Slot: T([
          {time: V('2014-12-16 13:00')}
          {time: V('2014-12-16 14:00')}
        ])
      })
      }
      {
      name: V('Matt McCutchen')
      Student: U({
        parent: V(I(5))
      })
      }
      {
      name: V('Michael McCutchen')
      Student: U({
        parent: V(I(5))
      })
      }
      {
      name: V('Shachar Itzhaky')
      Student: U({
        parent: V(I(6))
      })
      }
      {
      name: V('Rosemary McCutchen')
      }
      {
      name: V('Yoram Itzhaky')
      }
    ])
    Class: T([
      {
      code: V('6.170')
      name: V('Software Studio')
      Section: T([
        {
        teacher: V(I(0, 'X'))
        student: V(I(2, 'X'), I(3, 'X'))
        }
      ])
      }
      {
      code: V('6.*+~')
      name: V('Alloy')
      Section: T([
        {
        teacher: V(I(0, 'X'))
        student: V(I(2, 'X'), I(4, 'X'))
        }
      ])
      }
      {
      code: V('6.:::')
      name: V('Managed Time')
      Section: T([
        {
        teacher: V(I(1, 'X'))
        student: V(I(2, 'X'))
        }
      ])
      }
    ])
    Meeting: T([
      {
      enrollment: V(I(2, 0, I(2, 'X')))
      slot: V(I(1, 'X', 0))
      }
      {
      enrollment: V(I(0, 0, I(2, 'X')))
      slot: V(I(0, 'X', 1))
      }
      {
      enrollment: V(I(1, 0, I(2, 'X')))
      slot: V(I(0, 'X', 2))
      }
      {
      enrollment: V(I(0, 0, I(3, 'X')))
      slot: V(I(0, 'X', 3))
      }
      {
      enrollment: V(I(1, 0, I(4, 'X')))
      slot: V(I(0, 'X', 0))
      }
    ])
  }

  # Add a super dict representing _unit, though it doesn't get an ID or anything.
  superSchema = {children: sampleSchema}

  # Delete all existing columns!!
  model.drop()
  Views.remove {}

  console.log "Loading sample data into tablespace '#{$$.id}'"

  scanColumns = (parentId, schema) ->
    schema.children ?= []
    for columnDef, i in schema.children
      thisId = model.defineColumn(
        parentId, i,
        columnDef.name,
        # This only works because all of the types in our sample dataset refer to
        # columns that come earlier in preorder.  We can probably live with this
        # until we implement full validation of acyclic type usage.
        parseTypeStr(columnDef.type),
        columnDef.cellName,
        null  # formula
      )
      scanColumns(thisId, columnDef)
  scanColumns(rootColumnId, superSchema)

  # Insert cells into columns.
  insertCells = (columnId, cellId, cellData) ->
    for childColumnName, childCells of cellData ? {}
      childColumnId = childByName(model.getColumn(columnId), childColumnName)
      childColumn = new ColumnBinRel(childColumnId)
      for entry in childCells  # No point in making a map just to expand it again.
        [value, childCellData] = entry
        childColumn.add(cellId, value)
        insertCells(childColumnId, cellIdChild(cellId, value), childCellData)
  insertCells(rootColumnId, rootCellId, sampleData)

  # Add some formula columns.
  defineParsedFormulaColumn = (parentRef, order, name, cellName, specifiedType, formulaStr, attrs) ->
    # Ludicrously inefficient, but we need the column type fields to be set in
    # order to parse formulas.
    model.typecheckAll()
    parentId = parseColumnRef(parentRef)

    model.defineColumn(parentId,
                       order, name, cellName, specifiedType,
                       parseFormula(parentId, formulaStr), attrs)
  defineParsedFormulaColumn("Person:Student:parent",
                            0, "parentName", null, null,
                            'parent.name')
  defineParsedFormulaColumn("Person:Teacher:Slot",
                            1, "scheduledMeeting", null, null,
                            '{m : ::Meeting | m.slot = Slot}')

  defineParsedFormulaColumn("Person:Teacher:Slot:scheduledMeeting",
                            0, "discussed", null, null,
                            'scheduledMeeting.enrollment.student')
  defineParsedFormulaColumn("Person:Teacher:Slot:scheduledMeeting:discussed",
                            0, "studentName", null, null,
                            'discussed.Person.name')

  defineParsedFormulaColumn("Person",
                            1, "children", null, null,
                            '{c : ::Person | Person in c.Student.parent}',
                            {view: '1'})
  defineParsedFormulaColumn("Person:children",
                            0, "childName", null, null,
                            'children.name',
                            {view: '1'})

  model.evaluateAll()  # prepare dependencies

  # Create a view
  T = -> new Tree arguments...

  view1 =
    _id: '1'
    layout: T('_root', [T('Person', [T('Person:name'),
              T('Person:children', [T("Person:children:childName")])])])
            .map parseColumnRef

  Views.upsert(view1._id, view1)

  model
