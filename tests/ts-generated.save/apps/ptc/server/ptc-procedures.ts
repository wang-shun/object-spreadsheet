namespace Objsheets {

  RelsheetsServer.procedures("ptc", {
    teacherCreateSlot: {
      params: [["clientUser", "Person"], ["time", "text"]],
      body: "let t = clientUser.Teacher\ncheck t != {}\nlet s = new t.Slot\ns.time := time\ncheck $valid"
    },
    teacherDeleteSlot: {
      params: [["clientUser", "Person"], ["slot", "Person:Teacher:Slot"]],
      body: "check slot.Person = clientUser\ndelete slot\ncheck $valid"
    },
    parentCreateMeeting: {
      params: [["clientUser", "Person"], ["enr", "Class:Section:Enrollment"], ["slot", "Person:Teacher:Slot"]],
      body: "check clientUser in enr.student.parent\nlet m = new $Meeting\nm.enrollment := enr\nm.slot := slot\ncheck $valid"
    },
    parentCancelMeeting: {
      params: [["clientUser", "Person"], ["meeting", "Meeting"]],
      body: "check clientUser in meeting.enrollment.student.parent\ndelete meeting\ncheck $valid"
    },
    // This is just a test of a make statement, not something that actually belongs
    // in the PTC application.
    enroll: {
      params: [["student", "Person:Student"], ["section", "Class:Section"]],
      body: "make section.Enrollment[student]"
    }
  });

  // Future: Add special support for "check $valid"?  But we might want similar
  // functionality for other checks, if the Derailer study is any evidence.
  // Cleanup: Introduce a formula to reduce duplication in enrollment authorization
  // checks?

}
