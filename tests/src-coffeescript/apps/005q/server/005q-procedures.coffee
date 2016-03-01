RelsheetsServer.procedures '005q',
  enqueue:
    params: [['name', 'text'],
              ['issue', 'text'],
              ['location', 'text']]
    body: '''let q = new $Call
              q.time := d"now"
              q.name := name
              q.location := location
              q.issue := {s : $Skill | s.name = issue}'''
  pick:
    params: [['call', 'Call'],
              ['user', 'Staff']]
    body: '''call.assign := user'''
  forfeit:
    params: [['call', 'Call'],
              ['user', 'Staff']]
    body: '''call.assign := {}
              call.forfeit := user'''
  done:
    params: [['call', 'Call']]
    body: '''delete call'''
