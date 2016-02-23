if (Meteor.isServer) {
  Relsheets.procedures("ptc-study-solution", {
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