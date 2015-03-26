@loadPTCData = (model) ->
  # Sample schema and data in a more human-friendly hierarchical format.

  sampleSchema = [
    {
    type: '_token'
    objectName: 'Person'
    children: [
      {
      fieldName: 'name'
      type: '_string'
      # TODO: Required, singleton; probably unique but maybe not in schema
      }
      {
      type: '_unit'
      objectName: 'Student'
      # No need to constrain singleton.
      children: [
        fieldName: 'parent'
        type: 'Person'
        # There can be more than one parent, but there can be only one meeting per
        # enrollment, which we imagine several of the parents may attend if they
        # believe it is necessary.
        isObject: true
      ]
      }
      # We don't flag parents explicitly.  A person is a parent by virtue of being
      # the parent of some student.
      {
      type: '_unit'
      objectName: 'Teacher'
      children: [
        {
        type: '_token'
        objectName: 'Slot'
        children: [
          {
          # We don't normally expect the time of an existing slot to change, but
          # I'm now thinking it's wiser not to try to enforce that by making the
          # time a direct child of Teacher when it has no direct meaning in the
          # context of the Teacher.  Such decisions won't always be clear. ~ Matt
          fieldName: 'time'
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
    objectName: 'Class'
    children: [
      {
      fieldName: 'code'
      type: '_string'
      # TODO: Required, singleton, unique
      }
      {
      fieldName: 'name'
      type: '_string'
      # TODO: Required, singleton, unique (assuming department is sane)
      }
      {
      type: '_token'
      objectName: 'Section'
      children: [
        {
        fieldName: 'teacher'
        type: 'Person:Teacher'
        # TODO: Required, singleton
        }
        {
        # There's some doubt in my mind whether the enrollment should be thought
        # of as belonging to the section.  We might want to associate other data
        # (e.g., grades) with it that is as important to the student as it is to
        # the section.  But for now, this is useful as an example of having both
        # a fieldName and an objectName. ~ Matt
        fieldName: 'student'
        type: 'Person:Student'
        objectName: 'Enrollment'
        }
      ]
      }
    ]
    }
    {
    type: '_token'
    objectName: 'Meeting'
    children: [
      {
      fieldName: 'enrollment'
      type: 'Class:Section:Enrollment'
      # TODO: Required, singleton, unique
      }
      {
      fieldName: 'slot'
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
        '[parent]': V(I(5))
      })
      }
      {
      name: V('Michael McCutchen')
      Student: U({
        '[parent]': V(I(5))
      })
      }
      {
      name: V('Shachar Itzhaky')
      Student: U({
        '[parent]': V(I(6))
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
        Enrollment: V(I(2, 'X'), I(3, 'X'))
        }
      ])
      }
      {
      code: V('6.*+~')
      name: V('Alloy')
      Section: T([
        {
        teacher: V(I(0, 'X'))
        Enrollment: V(I(2, 'X'), I(4, 'X'))
        }
      ])
      }
      {
      code: V('6.:::')
      name: V('Managed Time')
      Section: T([
        {
        teacher: V(I(1, 'X'))
        Enrollment: V(I(2, 'X'))
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

  # Add a super dict representing _root, though it doesn't get an ID or anything.
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
        columnDef.fieldName,
        # This only works because all of the types in our sample dataset refer to
        # columns that come earlier in preorder.  We can probably live with this
        # until we implement full validation of acyclic type usage.
        parseTypeStr(columnDef.type),
        columnDef.objectName? || (columnDef.isObject ? false),
        columnDef.objectName,
        null  # formula
      )
      scanColumns(thisId, columnDef)
  scanColumns(rootColumnId, superSchema)

  # Insert cells into columns.
  insertCells = (columnId, cellId, cellData) ->
    for childColumnName, childCells of cellData ? {}
      # The sample data set uses the internal model with key and leaf columns
      # treated the same, so we don't care about the isValues part of the result.
      childColumnId = columnLogicalChildrenByName(columnId, childColumnName)[0][0]
      childColumn = new ColumnBinRel(childColumnId)
      for entry in childCells  # No point in making a map just to expand it again.
        [value, childCellData] = entry
        childColumn.add(cellId, value)
        insertCells(childColumnId, cellIdChild(cellId, value), childCellData)
  insertCells(rootColumnId, rootCellId, sampleData)

  # Add some formula columns.
  defineParsedFormulaColumn = (parentRef, order, fieldName, specifiedType, isObject, objectName, formulaStr, attrs) ->
    # Ludicrously inefficient, but we need the column type fields to be set in
    # order to parse formulas.
    model.typecheckAll()
    parentId = if parentRef then parseObjectTypeRef(parentRef) else rootColumnId

    model.defineColumn(parentId,
                       order, fieldName, specifiedType, isObject, objectName,
                       parseFormula(parentId, formulaStr), attrs)
  defineParsedFormulaColumn("Person:Student:[parent]",
                            0, "parentName", null, false, null,
                            'parent.name')
  defineParsedFormulaColumn("Person:Teacher:Slot",
                            1, "scheduledMeeting", null, true, null,
                            '{m : $Meeting | m.slot = Slot}')

  defineParsedFormulaColumn("Person:Teacher:Slot:[scheduledMeeting]",
                            0, "discussed", null, true, null,
                            'scheduledMeeting.enrollment.student')
  defineParsedFormulaColumn("Person:Teacher:Slot:[scheduledMeeting]:[discussed]",
                            0, "studentName", null, false, null,
                            'discussed.Person.name')

  # Example of a subscript expression; not currently needed for the PTC application.
  defineParsedFormulaColumn("Person:Student",
                            1, "enrollments", null, false, null,
                            '$Class.Section.Enrollment[Student]')

  defineParsedFormulaColumn("Class:Section:Enrollment",
                            0, "scheduledMeeting", null, false, null,
                            '{m : $Meeting | m.enrollment = Enrollment}')

  # Future: Add special support for referential integrity?
  defineParsedFormulaColumn("Meeting",
                            2, "valid", null, false, null,
                            'slot in $Person.Teacher.Slot && enrollment.Section.teacher = slot.Teacher')

  defineParsedFormulaColumn("Person",
                            1, "children", null, true, null,
                            '{c : $Person | Person in c.Student.[parent].parent}',
                            {view: '1'})
  defineParsedFormulaColumn("Person:[children]",
                            0, "childName", null, false, null,
                            'children.name',
                            {view: '1'})

  # Note, this only covers the constraints that can be broken by the
  # transactions we support.
  defineParsedFormulaColumn(
    "", 3, "valid", null, false, null,
    # XXX Change to universal quantification when available.
    '{e : $Class.Section.Enrollment | count(e.scheduledMeeting) > 1} = {} &&
     {s : $Person.Teacher.Slot | count(s.[scheduledMeeting].scheduledMeeting) > 1} = {} &&
     {m : $Meeting | !m.valid} = {}')

  model.evaluateAll()  # prepare dependencies

  # Create a view
  T = -> new Tree arguments...

  view1 =
    _id: '1'
    layout: T('', [T('Person', [T('Person:name'),
              T('Person:[children]', [T("Person:[children]:childName")])])])
            .map((s) -> if s then parseColumnRef(s)[0] else rootColumnId)

  Views.upsert(view1._id, view1)

  model


# Future: Add special support for "check $valid"?  But we might want similar
# functionality for other checks, if the Derailer study is any evidence.
# Cleanup: Introduce a formula to reduce duplication in enrollment authorization
# checks?
sampleProcedures = {
  teacherCreateSlot:
    params: [['clientUser', 'Person'],
             ['time', '_string']]
    body: '''
let t = clientUser.Teacher
check t != {}
let s = new t.Slot
s.time := time
check $valid
'''
  teacherDeleteSlot:
    params: [['clientUser', 'Person'],
             ['slot', 'Person:Teacher:Slot']]
    body: '''
check slot.Person = clientUser
delete slot
check $valid
'''
  parentCreateMeeting:
    params: [['clientUser', 'Person'],
             ['enr', 'Class:Section:Enrollment'],
             ['slot', 'Person:Teacher:Slot']]
    body: '''
check clientUser in enr.student.[parent].parent
let m = new $Meeting
m.enrollment := enr
m.slot := slot
check $valid
'''
  parentCancelMeeting:
    params: [['clientUser', 'Person'],
             ['meeting', 'Meeting']]
    body: '''
check clientUser in meeting.enrollment.student.[parent].parent
delete meeting
check $valid
'''

  # This is just a test of a make statement, not something that actually belongs
  # in the PTC application.
  enroll:
    params: [['student', 'Person:Student'],
             ['section', 'Class:Section']]
    body: '''
make section.Enrollment[student]
'''
}

@definePTCProcedures = (model) ->
  # Needed to parse procedures; server-startup evaluateAll hasn't run yet.
  model.typecheckAll()
  for name, proc of sampleProcedures
    try
      model.cannedTransactions.set(
        name, parseCannedTransaction(proc.params, proc.body))
    catch e
      # Incompatible schema change?
      console.log("Failed to define PTC sample procedure #{name}:", e.stack)

###
Example of calling a transaction from the browser console:

Meteor.call('executeCannedTransaction', $$, 'teacherCreateSlot', {clientUser: [["1"]], time: ['2014-12-16 15:00']})

Object IDs can be copied from the full text of the bullet cell.  Remember to
promote all arguments to lists.
###

@loadDump = (appName) ->
  try
    for [coll, collName] in [[Columns, 'columns'], [Cells, 'cells']]
      docs = JSON.parse(Assets.getText("dump/#{appName}:#{collName}.json"))
      for doc in docs
        coll.upsert(doc._id, doc)  # upsert needed to overwrite root column
  catch e
    console.log("Failed to load dump for #{appName} into sheet '#{$$.id}':", e.stack)
