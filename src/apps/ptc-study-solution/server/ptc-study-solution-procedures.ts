// The only thing different between this app subdirectory and ptc-study should be
// the procedure bodies (of course, the corresponding database dumps are also
// different), but it's easiest to fork the entire subdirectory.  Once we have
// the procedure editor and move the procedures to the database dumps, then we
// can use a single app name and subdirectory.


namespace Objsheets {

  RelsheetsServer.procedures("ptc-study-solution", {
    parentScheduleMeeting: {
      params: [["block", "FamilyPage:EnrollmentBlock:AvailableSlotBlock"]],
      body: "block.EnrollmentBlock.enrollment.scheduledSlot := block.slot"
    },
    parentCancelMeeting: {
      params: [["block", "FamilyPage:EnrollmentBlock:ExistingMeetingBlock"]],
      body: "block.EnrollmentBlock.enrollment.scheduledSlot := {}"
    }
  });

}
