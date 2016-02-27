if Meteor.isServer

  RelsheetsServer.procedures('ptc-study', {

    parentScheduleMeeting:
      params: [['block', 'FamilyPage:EnrollmentBlock:AvailableSlotBlock']]
      body: '''
check false
'''

    parentCancelMeeting:
      params: [['block', 'FamilyPage:EnrollmentBlock:ExistingMeetingBlock']]
      body: '''
check false
'''

    })
