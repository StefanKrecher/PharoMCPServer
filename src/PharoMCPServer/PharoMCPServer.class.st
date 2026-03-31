Class {
	#name : 'PharoMCPServer',
	#superclass : 'Object',
	#classVars : [
		'CurrentServer'
	],
	#category : 'PharoMCPServer',
	#package : 'PharoMCPServer'
}

{ #category : 'starting' }
PharoMCPServer class >> start [

	| server |
	self stop.
	server := ZnServer startDefaultOn: 7777.
	server delegate: self new.
	CurrentServer := server.
	^ server
]

{ #category : 'starting' }
PharoMCPServer class >> stop [

	CurrentServer ifNotNil: [
		CurrentServer stop.
		CurrentServer := nil ]
]

{ #category : 'responses' }
PharoMCPServer >> acceptedNoBodyResponse [

	^ self acceptedNoBodyResponseForSession: nil
]

{ #category : 'responses' }
PharoMCPServer >> acceptedNoBodyResponseForSession: aSessionId [

	| response |
	response := ZnResponse new.
	response statusLine: (ZnStatusLine code: 202).
	self addMcpHeadersTo: response sessionId: aSessionId.
	^ response
]

{ #category : 'mcp' }
PharoMCPServer >> addMcpHeadersTo: aResponse sessionId: aSessionId [

	aResponse headers at: 'Mcp-Protocol-Version' put: self supportedProtocolVersion.
	aSessionId ifNotNil: [ aResponse headers at: 'Mcp-Session-Id' put: aSessionId ]
]

{ #category : 'responses' }
PharoMCPServer >> badRequestResponse: aString [

	^ self plainResponse: aString status: 400 contentType: ZnMimeType textPlain
]

{ #category : 'tools' }
PharoMCPServer >> behaviorForClassName: className classSide: classSide [

	| cls |
	cls := Smalltalk at: className asSymbol ifAbsent: [ self error: 'Unknown class: ', className ].
	^ classSide = true ifTrue: [ cls class ] ifFalse: [ cls ]
]

{ #category : 'mcp' }
PharoMCPServer >> clientAcceptsJsonFor: aRequest [

	| accept |
	accept := aRequest headers at: 'Accept' ifAbsent: [ ^ true ].
	(accept includesSubstring: 'application/json') ifTrue: [ ^ true ].
	(accept includesSubstring: '*/*') ifTrue: [ ^ true ].
	^ false
]

{ #category : 'mcp' }
PharoMCPServer >> createSessionFor: params [

	| sessionId session |
	sessionId := self nextSessionId.
	session := Dictionary new.
	session at: 'createdAt' put: DateAndTime now asString.
	session at: 'clientInfo' put: (params at: 'clientInfo' ifAbsent: [ Dictionary new ]).
	session at: 'initialized' put: false.
	self sessionStore at: sessionId put: session.
	^ sessionId
]

{ #category : 'json' }
PharoMCPServer >> escapeJson: aString [

	| out ch |
	out := String streamContents: [ :stream |
		1 to: aString size do: [ :i |
			ch := aString at: i.
			ch = $" ifTrue: [ stream nextPutAll: '\"' ] ifFalse: [
				ch = Character cr ifTrue: [ stream nextPutAll: '\r' ] ifFalse: [
					ch = Character lf ifTrue: [ stream nextPutAll: '\n' ] ifFalse: [
						stream nextPut: ch ] ] ] ] ].
	^ out
]

{ #category : 'handling' }
PharoMCPServer >> evaluateCode: aString [

	^ self class compiler evaluate: aString
]

{ #category : 'json' }
PharoMCPServer >> extractCodeFrom: aString [

	| reader parsed start stop |
	reader := Smalltalk at: #NeoJSONReader ifAbsent: [ nil ].
	reader ifNotNil: [
		parsed := reader fromString: aString.
		^ parsed at: 'code' ifAbsent: [ self error: 'Missing code field' ] ].

	start := aString findString: '"code":"' startingAt: 1.
	start = 0 ifTrue: [
		start := aString findString: '"code": "' startingAt: 1 ].
	start = 0 ifTrue: [ self error: 'Missing code field' ].

	start := (aString indexOf: $" startingAt: start + 6) + 1.
	stop := aString indexOf: $" startingAt: start.
	stop = 0 ifTrue: [ self error: 'Invalid JSON body' ].
	^ aString copyFrom: start to: stop - 1
]

{ #category : 'handling' }
PharoMCPServer >> handleEvalRequest: aRequest [

	| body code result |
	(((aRequest method = #POST) or: [ aRequest method asString = 'POST' ])
		and: [ (aRequest uri path asString = '/eval') or: [ aRequest uri path asString = 'eval' ] ])
		ifFalse: [ ^ self jsonError: 'Only POST /eval is supported' status: 404 ].

	body := aRequest entity
		ifNil: [ '' ]
		ifNotNil: [ aRequest entity contents asString ].

	^ [
		code := self extractCodeFrom: body.
		result := self evaluateCode: code.
		self jsonResult: result printString ]
		on: Error
		do: [ :ex | self jsonError: ex messageText asString status: 500 ]
]

{ #category : 'handling' }
PharoMCPServer >> handleMcpDeleteRequest: aRequest [

	| sessionId session response |
	sessionId := self sessionIdFromRequest: aRequest.
	sessionId ifNil: [ ^ self badRequestResponse: 'Missing Mcp-Session-Id' ].
	session := self sessionAt: sessionId.
	session ifNil: [ ^ self notFoundResponse: 'Unknown session' ].
	self terminateSession: sessionId.
	response := ZnResponse noContent.
	self addMcpHeadersTo: response sessionId: nil.
	^ response
]

{ #category : 'handling' }
PharoMCPServer >> handleMcpPostRequest: aRequest [

	| body payload messages responses responseObjects onlyNotificationsOrResponses sessionId response |
	(self clientAcceptsJsonFor: aRequest) ifFalse: [ ^ self badRequestResponse: 'Client must accept application/json' ].
	body := aRequest entity ifNil: [ '' ] ifNotNil: [ aRequest entity contents asString ].
	body isEmpty ifTrue: [ ^ self badRequestResponse: 'Missing request body' ].
	payload := self parseJsonObject: body.
	(payload isKindOf: Array)
		ifTrue: [ messages := payload ]
		ifFalse: [ messages := Array with: payload ].
	messages isEmpty ifTrue: [ ^ self badRequestResponse: 'JSON-RPC batch must not be empty' ].
	sessionId := self sessionIdFromRequest: aRequest.
	responses := OrderedCollection new.
	responseObjects := false.
	onlyNotificationsOrResponses := true.
	messages do: [ :each |
		(self isJsonRpcResponseObject: each)
			ifTrue: [  ]
			ifFalse: [
				(self isJsonRpcNotification: each) ifFalse: [ onlyNotificationsOrResponses := false ].
				(self processMcpMessage: each sessionId: sessionId) ifNotNil: [ :responsePayload |
					responses add: responsePayload.
					responseObjects := true ] ] ].
	(onlyNotificationsOrResponses and: [ responseObjects not ]) ifTrue: [ ^ self acceptedNoBodyResponseForSession: sessionId ].
	response := responses size = 1
		ifTrue: [ self jsonObjectResponse: responses first status: 200 ]
		ifFalse: [ self jsonObjectResponse: responses asArray status: 200 ].
	self addMcpHeadersTo: response sessionId: sessionId.
	^ response
]

{ #category : 'handling' }
PharoMCPServer >> handleMcpTransportRequest: aRequest [

	| method |
	self validateOriginFor: aRequest.
	method := aRequest method asString.
	method = 'POST' ifTrue: [ ^ self handleMcpPostRequest: aRequest ].
	method = 'DELETE' ifTrue: [ ^ self handleMcpDeleteRequest: aRequest ].
	method = 'GET' ifTrue: [ ^ self methodNotAllowedResponse ].
	^ self methodNotAllowedResponse
]

{ #category : 'handling' }
PharoMCPServer >> handleRequest: aRequest [

	| path |
	path := aRequest uri path asString.
	((path = '/eval') or: [ path = 'eval' ]) ifTrue: [ ^ self handleEvalRequest: aRequest ].
	((path = '/mcp') or: [ path = 'mcp' ]) ifTrue: [ ^ self handleMcpTransportRequest: aRequest ].
	^ self notFoundResponse: 'Only /eval or /mcp is supported'
]

{ #category : 'mcp' }
PharoMCPServer >> isJsonRpcNotification: anObject [

	(self isJsonRpcRequest: anObject) ifFalse: [ ^ false ].
	^ (anObject includesKey: 'id') not
]

{ #category : 'mcp' }
PharoMCPServer >> isJsonRpcRequest: anObject [

	(anObject isKindOf: Dictionary) ifFalse: [ ^ false ].
	(anObject includesKey: 'method') ifFalse: [ ^ false ].
	(anObject includesKey: 'jsonrpc') ifFalse: [ ^ false ].
	^ true
]

{ #category : 'mcp' }
PharoMCPServer >> isJsonRpcResponseObject: anObject [

	(anObject isKindOf: Dictionary) ifFalse: [ ^ false ].
	(anObject includesKey: 'jsonrpc') ifFalse: [ ^ false ].
	(anObject includesKey: 'method') ifTrue: [ ^ false ].
	(anObject includesKey: 'result') ifTrue: [ ^ true ].
	(anObject includesKey: 'error') ifTrue: [ ^ true ].
	^ false
]

{ #category : 'mcp' }
PharoMCPServer >> isSessionInitialized: aSessionId [

	| session |
	session := self sessionAt: aSessionId.
	session ifNil: [ ^ false ].
	^ session at: 'initialized' ifAbsent: [ false ]
]

{ #category : 'json' }
PharoMCPServer >> jsonError: aMessage status: aStatus [

	^ self
		jsonResponse: ('{"error":"', (self escapeJson: aMessage), '"}')
		status: aStatus
]

{ #category : 'json' }
PharoMCPServer >> jsonObjectResponse: anObject status: aStatus [

	| response entity payload meta sessionId |
	payload := anObject copy.
	meta := nil.
	(payload isKindOf: Dictionary) ifTrue: [
		meta := payload at: '_meta' ifAbsent: [ nil ].
		payload removeKey: '_meta' ifAbsent: [ nil ] ].
	entity := ZnEntity text: (self serializeObjectAsJson: payload).
	entity contentType: ZnMimeType applicationJson.
	response := ZnResponse new.
	response statusLine: (ZnStatusLine code: aStatus).
	response entity: entity.
	meta ifNotNil: [
		sessionId := meta at: 'mcpSessionId' ifAbsent: [ nil ].
		sessionId ifNotNil: [ response headers at: 'Mcp-Session-Id' put: sessionId ].
		response headers at: 'Mcp-Protocol-Version' put: self supportedProtocolVersion ].
	^ response
]

{ #category : 'json' }
PharoMCPServer >> jsonResponse: aString status: aStatus [

	| response entity |
	entity := ZnEntity text: aString.
	entity contentType: ZnMimeType applicationJson.
	response := ZnResponse new.
	response statusLine: (ZnStatusLine code: aStatus).
	response entity: entity.
	^ response
]

{ #category : 'json' }
PharoMCPServer >> jsonResult: aString [

	^ self
		jsonResponse: ('{"result":"', (self escapeJson: aString), '"}')
		status: 200
]

{ #category : 'mcp' }
PharoMCPServer >> jsonRpcErrorPayloadCode: aCode message: aMessage id: anId data: someData [

	| error payload |
	error := Dictionary new.
	error at: 'code' put: aCode.
	error at: 'message' put: aMessage.
	someData ifNotNil: [ error at: 'data' put: someData ].
	payload := Dictionary new.
	payload at: 'jsonrpc' put: '2.0'.
	payload at: 'id' put: anId.
	payload at: 'error' put: error.
	^ payload
]

{ #category : 'mcp' }
PharoMCPServer >> jsonRpcResultPayload: aResult id: anId [

	^ self jsonRpcResultPayload: aResult id: anId sessionId: nil
]

{ #category : 'mcp' }
PharoMCPServer >> jsonRpcResultPayload: aResult id: anId sessionId: aSessionId [

	| payload |
	payload := Dictionary new.
	payload at: 'jsonrpc' put: '2.0'.
	payload at: 'id' put: anId.
	payload at: 'result' put: aResult.
	aSessionId ifNotNil: [ payload at: '_meta' put: (Dictionary new at: 'mcpSessionId' put: aSessionId; yourself) ].
	^ payload
]

{ #category : 'tools' }
PharoMCPServer >> jsonTextFor: anObject [

	^ self serializeObjectAsJson: anObject
]

{ #category : 'mcp' }
PharoMCPServer >> markSessionInitialized: aSessionId [

	| session |
	session := self sessionAt: aSessionId.
	session ifNotNil: [ session at: 'initialized' put: true ]
]

{ #category : 'mcp' }
PharoMCPServer >> mcpHandleToolCall: params [

	| name arguments text |
	name := params at: 'name' ifAbsent: [ self error: 'Missing tool name' ].
	arguments := params at: 'arguments' ifAbsent: [ Dictionary new ].
	^[
		text := name = 'pharo_eval'
			ifTrue: [ (self evaluateCode: (arguments at: 'code' ifAbsent: [ self error: 'Missing code argument' ])) printString ]
			ifFalse: [ self performToolNamed: name with: arguments ].
		self mcpToolResultText: text isError: false ]
		on: Error
		do: [ :ex | self mcpToolResultText: ex messageText asString isError: true ]
]

{ #category : 'mcp' }
PharoMCPServer >> mcpInitializeResult [

	| capabilities serverInfo result |
	capabilities := Dictionary new.
	capabilities at: 'tools' put: (Dictionary new at: 'listChanged' put: false; yourself).
	serverInfo := Dictionary new.
	serverInfo at: 'name' put: 'pharo-mcp'.
	serverInfo at: 'version' put: '0.1.0'.
	result := Dictionary new.
	result at: 'protocolVersion' put: self supportedProtocolVersion.
	result at: 'capabilities' put: capabilities.
	result at: 'serverInfo' put: serverInfo.
	^ result
]

{ #category : 'tools' }
PharoMCPServer >> mcpToolResultText: aString isError: aBoolean [

	| item result |
	item := Dictionary new.
	item at: 'type' put: 'text'.
	item at: 'text' put: aString.
	result := Dictionary new.
	result at: 'content' put: (Array with: item).
	result at: 'isError' put: aBoolean.
	^ result
]

{ #category : 'mcp' }
PharoMCPServer >> mcpToolsListResult [

	| tools addTool result |
	tools := OrderedCollection new.
	addTool := [ :name :description :properties :required |
		| tool schema |
		schema := Dictionary new.
		schema at: 'type' put: 'object'.
		schema at: 'properties' put: properties.
		schema at: 'required' put: required.
		tool := Dictionary new.
		tool at: 'name' put: name.
		tool at: 'description' put: description.
		tool at: 'inputSchema' put: schema.
		tools add: tool ].
	addTool value: 'pharo_eval' value: 'Evaluate a Smalltalk expression in the running Pharo image' value: (Dictionary new at: 'code' put: (Dictionary new at: 'type' put: 'string'; at: 'description' put: 'Smalltalk code to evaluate'; yourself); yourself) value: (Array with: 'code').
	addTool value: 'pharo_get_class' value: 'Get basic information about a class' value: (Dictionary new at: 'className' put: (Dictionary new at: 'type' put: 'string'; yourself); yourself) value: (Array with: 'className').
	addTool value: 'pharo_list_methods' value: 'List methods on a class, optionally filtered by protocol' value: (Dictionary new at: 'className' put: (Dictionary new at: 'type' put: 'string'; yourself); at: 'classSide' put: (Dictionary new at: 'type' put: 'boolean'; yourself); at: 'protocol' put: (Dictionary new at: 'type' put: 'string'; yourself); yourself) value: (Array with: 'className').
	addTool value: 'pharo_get_method_source' value: 'Get the source code for a method' value: (Dictionary new at: 'className' put: (Dictionary new at: 'type' put: 'string'; yourself); at: 'classSide' put: (Dictionary new at: 'type' put: 'boolean'; yourself); at: 'selector' put: (Dictionary new at: 'type' put: 'string'; yourself); yourself) value: (Array with: 'className' with: 'selector').
	addTool value: 'pharo_compile_method' value: 'Compile a method on a class' value: (Dictionary new at: 'className' put: (Dictionary new at: 'type' put: 'string'; yourself); at: 'classSide' put: (Dictionary new at: 'type' put: 'boolean'; yourself); at: 'protocol' put: (Dictionary new at: 'type' put: 'string'; yourself); at: 'source' put: (Dictionary new at: 'type' put: 'string'; yourself); yourself) value: (Array with: 'className' with: 'source').
	addTool value: 'pharo_find_references' value: 'Find implementors, senders, or source text matches' value: (Dictionary new at: 'kind' put: (Dictionary new at: 'type' put: 'string'; yourself); at: 'query' put: (Dictionary new at: 'type' put: 'string'; yourself); yourself) value: (Array with: 'kind' with: 'query').
	addTool value: 'pharo_run_tests' value: 'Run Pharo tests by class or selector' value: (Dictionary new at: 'className' put: (Dictionary new at: 'type' put: 'string'; yourself); at: 'classNames' put: (Dictionary new at: 'type' put: 'array'; yourself); at: 'selectors' put: (Dictionary new at: 'type' put: 'array'; yourself); yourself) value: #().
	result := Dictionary new.
	result at: 'tools' put: tools asArray.
	^ result
]

{ #category : 'responses' }
PharoMCPServer >> methodNotAllowedResponse [

	| response |
	response := self plainResponse: 'Method not allowed' status: 405 contentType: ZnMimeType textPlain.
	response headers at: 'Allow' put: 'POST, DELETE'.
	^ response
]

{ #category : 'mcp' }
PharoMCPServer >> nextSessionId [

	^ UUID new asString
]

{ #category : 'responses' }
PharoMCPServer >> noContentResponse [

	^ ZnResponse noContent
]

{ #category : 'responses' }
PharoMCPServer >> notFoundResponse: aString [

	^ self plainResponse: aString status: 404 contentType: ZnMimeType textPlain
]

{ #category : 'json' }
PharoMCPServer >> parseJsonObject: aString [

	| reader |
	reader := Smalltalk at: #NeoJSONReader ifAbsent: [ self error: 'NeoJSONReader not available' ].
	^ reader fromString: aString
]

{ #category : 'tools' }
PharoMCPServer >> performToolNamed: name with: arguments [

	name = 'pharo_get_class' ifTrue: [ ^ self toolGetClass: arguments ].
	name = 'pharo_list_methods' ifTrue: [ ^ self toolListMethods: arguments ].
	name = 'pharo_get_method_source' ifTrue: [ ^ self toolGetMethodSource: arguments ].
	name = 'pharo_compile_method' ifTrue: [ ^ self toolCompileMethod: arguments ].
	name = 'pharo_find_references' ifTrue: [ ^ self toolFindReferences: arguments ].
	name = 'pharo_run_tests' ifTrue: [ ^ self toolRunTests: arguments ].
	self error: 'Unknown tool'
]

{ #category : 'responses' }
PharoMCPServer >> plainResponse: aString status: aStatus contentType: aMimeType [

	| response entity |
	entity := ZnEntity text: aString.
	entity contentType: aMimeType.
	response := ZnResponse new.
	response statusLine: (ZnStatusLine code: aStatus).
	response entity: entity.
	^ response
]

{ #category : 'mcp' }
PharoMCPServer >> processInitializeMessage: aMessage [

	| id params requestedVersion sessionId result supported meta |
	id := aMessage at: 'id' ifAbsent: [ nil ].
	params := aMessage at: 'params' ifAbsent: [ Dictionary new ].
	requestedVersion := params at: 'protocolVersion' ifAbsent: [ nil ].
	supported := self supportedProtocolVersion.
	requestedVersion = supported
		ifFalse: [ ^ self jsonRpcErrorPayloadCode: -32602 message: 'Unsupported protocol version' id: id data: (Dictionary new at: 'supported' put: (Array with: supported); at: 'requested' put: requestedVersion; yourself) ].
	sessionId := self createSessionFor: params.
	result := self mcpInitializeResult.
	result at: 'protocolVersion' put: supported.
	meta := Dictionary new.
	meta at: 'mcpSessionId' put: sessionId.
	result at: '_meta' put: meta.
	^ self jsonRpcResultPayload: result id: id sessionId: sessionId
]

{ #category : 'mcp' }
PharoMCPServer >> processInitializedNotificationWithSessionId: sessionId [

	sessionId ifNil: [ self error: 'Missing Mcp-Session-Id' ].
	(self sessionAt: sessionId) ifNil: [ self error: 'Unknown session' ].
	self markSessionInitialized: sessionId
]

{ #category : 'mcp' }
PharoMCPServer >> processMcpMessage: aMessage sessionId: sessionId [

	| method id params |
	(self isJsonRpcRequest: aMessage) ifFalse: [ ^ self jsonRpcErrorPayloadCode: -32600 message: 'Invalid Request' id: nil data: nil ].
	(aMessage at: 'jsonrpc' ifAbsent: [ nil ]) = '2.0' ifFalse: [ ^ self jsonRpcErrorPayloadCode: -32600 message: 'Invalid Request' id: (aMessage at: 'id' ifAbsent: [ nil ]) data: nil ].
	method := aMessage at: 'method' ifAbsent: [ ^ self jsonRpcErrorPayloadCode: -32600 message: 'Invalid Request' id: nil data: nil ].
	id := aMessage at: 'id' ifAbsent: [ nil ].
	params := aMessage at: 'params' ifAbsent: [ Dictionary new ].
	method = 'initialize' ifTrue: [ ^ self processInitializeMessage: aMessage ].
	method = 'notifications/initialized' ifTrue: [ self processInitializedNotificationWithSessionId: sessionId. ^ nil ].
	sessionId isNil ifTrue: [
		method = 'ping'
			ifFalse: [ ^ self jsonRpcErrorPayloadCode: -32001 message: 'Missing Mcp-Session-Id' id: id data: nil ] ].
	(sessionId notNil and: [ (self sessionAt: sessionId) isNil ]) ifTrue: [ ^ self jsonRpcErrorPayloadCode: -32002 message: 'Unknown session' id: id data: nil ].
	(method = 'ping') ifFalse: [
		(method = 'notifications/initialized') ifFalse: [
			(sessionId notNil and: [ (self isSessionInitialized: sessionId) not ]) ifTrue: [
				^ self jsonRpcErrorPayloadCode: -32003 message: 'Session not initialized' id: id data: nil ] ] ].
	method = 'ping' ifTrue: [ ^ id ifNil: [ nil ] ifNotNil: [ self jsonRpcResultPayload: Dictionary new id: id ] ].
	method = 'tools/list' ifTrue: [ ^ id ifNil: [ nil ] ifNotNil: [ self jsonRpcResultPayload: self mcpToolsListResult id: id ] ].
	method = 'tools/call' ifTrue: [ ^ id ifNil: [ nil ] ifNotNil: [ self jsonRpcResultPayload: (self mcpHandleToolCall: params) id: id ] ].
	^ id ifNil: [ nil ] ifNotNil: [ self jsonRpcErrorPayloadCode: -32601 message: 'Method not found' id: id data: nil ]
]

{ #category : 'tools' }
PharoMCPServer >> referenceRecordForMethod: methodRef kind: kind [

	| dict cls selector |
	cls := (methodRef respondsTo: #methodClass)
		ifTrue: [ methodRef methodClass ]
		ifFalse: [ methodRef actualClass ].
	selector := methodRef selector.
	dict := Dictionary new.
	dict at: 'kind' put: kind.
	dict at: 'className' put: cls name asString.
	dict at: 'selector' put: selector asString.
	dict at: 'protocol' put: ((cls >> selector) protocol asString).
	^ dict
]

{ #category : 'json' }
PharoMCPServer >> serializeObjectAsJson: anObject [

	| writer |
	writer := Smalltalk at: #NeoJSONWriter ifAbsent: [ self error: 'NeoJSONWriter not available' ].
	^ writer toString: anObject
]

{ #category : 'mcp' }
PharoMCPServer >> sessionAt: aSessionId [

	^ self sessionStore at: aSessionId ifAbsent: [ nil ]
]

{ #category : 'mcp' }
PharoMCPServer >> sessionIdFromRequest: aRequest [

	^ aRequest headers at: 'Mcp-Session-Id' ifAbsent: [ nil ]
]

{ #category : 'mcp' }
PharoMCPServer >> sessionStore [

	^ Smalltalk globals at: #PharoMCPSessions ifAbsentPut: [ Dictionary new ]
]

{ #category : 'mcp' }
PharoMCPServer >> supportedProtocolVersion [

	^ '2025-06-18'
]

{ #category : 'mcp' }
PharoMCPServer >> terminateSession: aSessionId [

	self sessionStore removeKey: aSessionId ifAbsent: [ nil ]
]

{ #category : 'tools' }
PharoMCPServer >> toolCompileMethod: arguments [

	| className classSide source protocol behavior selector result |
	className := arguments at: 'className' ifAbsent: [ self error: 'Missing className' ].
	classSide := arguments at: 'classSide' ifAbsent: [ false ].
	source := arguments at: 'source' ifAbsent: [ self error: 'Missing source' ].
	protocol := arguments at: 'protocol' ifAbsent: [ 'as yet unclassified' ].
	behavior := self behaviorForClassName: className classSide: classSide.
	selector := behavior compile: source classified: protocol.
	result := Dictionary new.
	result at: 'className' put: className.
	result at: 'classSide' put: classSide.
	result at: 'selector' put: selector asString.
	result at: 'protocol' put: protocol.
	^ self jsonTextFor: result
]

{ #category : 'tools' }
PharoMCPServer >> toolFindReferences: arguments [

	| kind query nav refs result needle |
	kind := arguments at: 'kind' ifAbsent: [ 'implementors' ].
	query := arguments at: 'query' ifAbsent: [ self error: 'Missing query' ].
	nav := SystemNavigation default.
	kind = 'implementors' ifTrue: [
		refs := nav allImplementorsOf: query asSymbol.
		result := refs collect: [ :each | self referenceRecordForMethod: each kind: kind ].
		^ self jsonTextFor: result ].
	kind = 'senders' ifTrue: [
		refs := nav allCallsOn: query asSymbol.
		result := refs collect: [ :each | self referenceRecordForMethod: each kind: kind ].
		^ self jsonTextFor: result ].
	kind = 'text' ifTrue: [
		needle := query asString.
		result := OrderedCollection new.
		Smalltalk allClassesDo: [ :cls |
			cls selectors do: [ :sel |
				| source |
				source := cls sourceCodeAt: sel ifAbsent: [ '' ].
				(source includesSubstring: needle) ifTrue: [ result add: (self referenceRecordForMethod: (cls >> sel) kind: kind) ] ].
			cls class selectors do: [ :sel |
				| source |
				source := cls class sourceCodeAt: sel ifAbsent: [ '' ].
				(source includesSubstring: needle) ifTrue: [ result add: (self referenceRecordForMethod: (cls class >> sel) kind: kind) ] ] ].
		^ self jsonTextFor: result asArray ].
	self error: 'Unknown reference search kind'
]

{ #category : 'tools' }
PharoMCPServer >> toolGetClass: arguments [

	| className behavior cls result |
	className := arguments at: 'className' ifAbsent: [ self error: 'Missing className' ].
	behavior := self behaviorForClassName: className classSide: false.
	cls := behavior.
	result := Dictionary new.
	result at: 'name' put: cls name asString.
	result at: 'superclass' put: (cls superclass ifNil: [ nil ] ifNotNil: [ cls superclass name asString ]).
	result at: 'instanceVariables' put: (cls instVarNames collect: [ :each | each asString ]).
	result at: 'classVariables' put: (cls classVarNames collect: [ :each | each asString ]).
	result at: 'category' put: (cls category ifNil: [ '' ]).
	result at: 'classSideSelectors' put: cls class selectors size.
	result at: 'instanceSideSelectors' put: cls selectors size.
	^ self jsonTextFor: result
]

{ #category : 'tools' }
PharoMCPServer >> toolGetMethodSource: arguments [

	| className classSide selector behavior method result |
	className := arguments at: 'className' ifAbsent: [ self error: 'Missing className' ].
	classSide := arguments at: 'classSide' ifAbsent: [ false ].
	selector := (arguments at: 'selector' ifAbsent: [ self error: 'Missing selector' ]) asSymbol.
	behavior := self behaviorForClassName: className classSide: classSide.
	method := behavior >> selector.
	result := Dictionary new.
	result at: 'className' put: className.
	result at: 'classSide' put: classSide.
	result at: 'selector' put: selector asString.
	result at: 'protocol' put: method protocol asString.
	result at: 'source' put: (behavior sourceCodeAt: selector).
	^ self jsonTextFor: result
]

{ #category : 'tools' }
PharoMCPServer >> toolListMethods: arguments [

	| className classSide behavior protocol selectors result |
	className := arguments at: 'className' ifAbsent: [ self error: 'Missing className' ].
	classSide := arguments at: 'classSide' ifAbsent: [ false ].
	protocol := arguments at: 'protocol' ifAbsent: [ nil ].
	behavior := self behaviorForClassName: className classSide: classSide.
	selectors := behavior selectors asSortedCollection.
	protocol ifNotNil: [
		selectors := selectors select: [ :sel | (behavior >> sel) protocol = protocol ] ].
	result := Dictionary new.
	result at: 'className' put: className.
	result at: 'classSide' put: classSide.
	protocol ifNotNil: [ result at: 'protocol' put: protocol ].
	result at: 'selectors' put: (selectors collect: [ :sel | sel asString ]).
	^ self jsonTextFor: result
]

{ #category : 'tools' }
PharoMCPServer >> toolRunTests: arguments [

	| classNames selectors suite result run classes tests |
	classNames := arguments at: 'classNames' ifAbsent: [ Array with: (arguments at: 'className' ifAbsent: [ self error: 'Missing className or classNames' ]) ].
	selectors := arguments at: 'selectors' ifAbsent: [ #() ].
	classes := classNames collect: [ :each |
		Smalltalk at: each asSymbol ifAbsent: [ self error: 'Unknown test class: ', each ] ].
	suite := TestSuite named: 'MCP requested tests'.
	selectors isEmpty
		ifTrue: [ classes do: [ :cls | suite addTests: cls suite tests ] ]
		ifFalse: [
			classNames size = 1 ifFalse: [ self error: 'selectors currently require exactly one className' ].
			tests := selectors collect: [ :sel | (classes first selector: sel asSymbol) ].
			suite addTests: tests ].
	run := suite run.
	result := Dictionary new.
	result at: 'runCount' put: run runCount.
	result at: 'passed' put: run passedCount.
	result at: 'failures' put: (run failures collect: [ :each | each printString ]).
	result at: 'errors' put: (run errors collect: [ :each | each printString ]).
	result at: 'hasPassed' put: run hasPassed.
	^ self jsonTextFor: result
]

{ #category : 'responses' }
PharoMCPServer >> unsupportedMediaTypeResponse [

	^ self plainResponse: 'Unsupported media type' status: 415 contentType: ZnMimeType textPlain
]

{ #category : 'mcp' }
PharoMCPServer >> validateOriginFor: aRequest [

	| origin allowed |
	origin := aRequest headers at: 'Origin' ifAbsent: [ ^ self ].
	allowed := false.
	(origin beginsWith: 'http://127.0.0.1') ifTrue: [ allowed := true ].
	(origin beginsWith: 'http://localhost') ifTrue: [ allowed := true ].
	(origin beginsWith: 'https://127.0.0.1') ifTrue: [ allowed := true ].
	(origin beginsWith: 'https://localhost') ifTrue: [ allowed := true ].
	allowed ifFalse: [ self error: 'Invalid Origin header' ]
]

{ #category : 'accessing' }
PharoMCPServer >> value: aRequest [

	^ self handleRequest: aRequest
]
