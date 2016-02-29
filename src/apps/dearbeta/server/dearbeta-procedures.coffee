RelsheetsServer.procedures "beta",
  requestUp:
    params: [['at', 'File:Node:Time']]
    body: '''new at.Request'''
  requestDown:
    params: [['at', 'File:Node:Time']]
    body: '''delete oneOf(at.Request)'''
  hintUp:
    params: [['at', 'File:Node:Time:Hint']]
    body: '''new at.Vote'''
  hintDown:
    params: [['at', 'File:Node:Time:Hint']]
    body: '''delete oneOf(at.Vote)'''
  hintAdd:
    params: [['at', 'File:Node:Time'], ['text', 'text']]
    body: '''let h = new at.Hint
              h.body := text'''
  hintDel:
    params: [['at', 'File:Node:Time:Hint']]
    body: '''delete at'''
