RelsheetsServer.procedures 'ptc',
  teacherCreateSlot:
    params: [['clientUser', 'Person'],
              ['time', 'text']]
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
check clientUser in enr.student.parent
let m = new $Meeting
m.enrollment := enr
m.slot := slot
check $valid
'''
  parentCancelMeeting:
    params: [['clientUser', 'Person'],
              ['meeting', 'Meeting']]
    body: '''
check clientUser in meeting.enrollment.student.parent
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

# Future: Add special support for "check $valid"?  But we might want similar
# functionality for other checks, if the Derailer study is any evidence.
# Cleanup: Introduce a formula to reduce duplication in enrollment authorization
# checks?
