;;; json.ss -- stable external projections of canonical datums.

(define (usage->json usage)
  (if (list? usage)
      `((input . ,(or (assq-ref usage 'input) 0))
        (output . ,(or (assq-ref usage 'output) 0))
        (cacheRead . ,(or (assq-ref usage 'cache-read) 0))
        (cacheWrite . ,(or (assq-ref usage 'cache-write) 0)))
      '()))

(define (call->json call)
  (match call
    [(call ,id ,name ,args)
     `((id . ,id) (name . ,name) (arguments . ,args))]
    [,other `((invalid . ,(format "~s" other)))]))

(define (message->json message)
  (match message
    [(msg user ,content)
     `((role . user) (content . ,content))]
    [(msg system ,content)
     `((role . system) (content . ,content))]
    [(msg assistant ,content ,calls ,stop ,usage)
     `((role . assistant)
       (content . ,content)
       (toolCalls . ,(list->vector (map call->json calls)))
       (stopReason . ,stop)
       (usage . ,(usage->json usage)))]
    [(msg tool ,id ,name ,content ,error?)
     `((role . tool)
       (toolCallId . ,id)
       (toolName . ,name)
       (content . ,content)
       (isError . ,(and error? #t)))]
    [,other
     `((role . unknown) (datum . ,(format "~s" other)))]))

(define (entry-json type id parent timestamp fields)
  (append
   `((type . ,type)
     (id . ,id)
     (parentId . ,(or parent 'null))
     (timestamp . ,timestamp))
   fields))

(define (entry->json entry)
  (match entry
    [(message ,id ,parent ,ts ,message)
     (entry-json
      'message id parent ts
      `((message . ,(message->json message))))]
    [(compaction ,id ,parent ,ts ,summary ,first ,tokens ,details)
     (entry-json
      'compaction id parent ts
      `((summary . ,summary)
        (firstKeptEntryId . ,(or first 'null))
        (tokensBefore . ,tokens)
        (details . ,(format "~s" details))))]
    [(branch-summary ,id ,parent ,ts ,from ,summary)
     (entry-json
      'branch_summary id parent ts
      `((fromId . ,(or from 'null))
        (summary . ,summary)))]
    [(label ,id ,parent ,ts ,target ,label)
     (entry-json
      'label id parent ts
      `((targetId . ,(or target 'null))
        (label . ,(or label 'null))))]
    [(session-info ,id ,parent ,ts ,name)
     (entry-json 'session_info id parent ts `((name . ,name)))]
    [(custom ,id ,parent ,ts ,kind ,data)
     (entry-json
      'custom id parent ts
      `((customType . ,kind)
        (data . ,(format "~s" data))))]
    [(custom-message ,id ,parent ,ts ,kind ,content ,display?)
     (entry-json
      'custom_message id parent ts
      `((customType . ,kind)
        (content . ,content)
        (display . ,(and display? #t))))]
    [(model-change ,id ,parent ,ts ,provider ,model)
     (entry-json
      'model_change id parent ts
      `((provider . ,provider) (model . ,model)))]
    [(thinking-level ,id ,parent ,ts ,level)
     (entry-json
      'thinking_level_change id parent ts
      `((level . ,level)))]
    [(scope-form ,id ,parent ,ts ,form)
     (entry-json
      'scope_form id parent ts
      `((form . ,(format "~s" form))))]
    [,other
     `((type . unknown)
       (datum . ,(format "~s" other)))]))

(define (json-event-value value)
  (if (or (string? value)
          (number? value)
          (boolean? value)
          (symbol? value))
      value
      (format "~s" value)))

(define (event-json type fields)
  (cons (cons 'type type) fields))

(define (event->json event)
  (match event
    [(ev agent-start) (event-json 'agent_start '())]
    [(ev agent-end) (event-json 'agent_end '())]
    [(ev agent-settled) (event-json 'agent_settled '())]
    [(ev turn-start ,step)
     (event-json 'turn_start `((step . ,step)))]
    [(ev turn-end ,step)
     (event-json 'turn_end `((step . ,step)))]
    [(ev message-start) (event-json 'message_start '())]
    [(ev message-delta ,text)
     (event-json
      'message_update
      `((assistantMessageEvent
         . ((type . text_delta) (delta . ,text)))))]
    [(ev thinking-delta ,text)
     (event-json
      'message_update
      `((assistantMessageEvent
         . ((type . thinking_delta) (delta . ,text)))))]
    [(ev message-end ,message)
     (event-json
      'message_end
      `((message . ,(message->json message))))]
    [(ev tool-start ,id ,name ,args)
     (event-json
      'tool_execution_start
      `((toolCallId . ,id) (toolName . ,name) (args . ,args)))]
    [(ev tool-end ,id ,name ,error? ,output)
     (event-json
      'tool_execution_end
      `((toolCallId . ,id) (toolName . ,name)
        (isError . ,(and error? #t)) (output . ,output)))]
    [(ev session-start ,session ,reason ,previous)
     (event-json
      'session_start
      `((sessionId . ,(session-id session))
        (sessionFile . ,(or (session-file session) 'null))
        (reason . ,reason)
        (previousSessionFile . ,(or previous 'null))))]
    [(ev session-end ,session ,reason ,target)
     (event-json
      'session_end
      `((sessionId . ,(session-id session))
        (reason . ,reason)
        (targetSessionFile . ,(or target 'null))))]
    [(ev session-recovered ,session ,recovery)
     (event-json
      'session_recovered
      `((sessionId . ,(session-id session))
        (recovery . ,(format "~s" recovery))))]
    [(ev plugin-mount ,name)
     (event-json 'plugin_mount `((plugin . ,name)))]
    [(ev plugin-dispose ,name)
     (event-json 'plugin_dispose `((plugin . ,name)))]
    [(ev plugin-op ,name ,kind ,description)
     (event-json
      'plugin_op
      `((plugin . ,name) (op . ,kind)
        (description . ,description)))]
    [(ev model-change ,provider ,model)
     (event-json
      'model_change
      `((provider . ,provider) (model . ,model)))]
    [(ev thinking-level-change ,level)
     (event-json 'thinking_level_change `((level . ,level)))]
    [(ev ,kind . ,payload)
     (event-json
      kind
      `((payload
         . ,(list->vector (map json-event-value payload)))))]
    [,other
     `((type . unknown)
       (datum . ,(format "~s" other)))]))
