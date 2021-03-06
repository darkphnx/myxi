window.Myxi ||= {}
class Myxi.Connection

  constructor: (serverURL)->
    @serverURL = serverURL
    @connected = false
    @authenticated = false
    @subscriptions = {}
    @callbacks = {}
    @reconnect = true
    @reconnectTimer = null
    @authentication_callback = null
    @connect()

  connect: ->
    clearTimeout(@reconnectTimer) if @reconnectTimer?
    @websocket = new WebSocket(@serverURL)
    @websocket.onopen = (event)=>
      console.log "Connected to socket server at #{@serverURL}"
      if @connected == false
        @_runCallbacks('SocketConnected')
      @connected = true
      if @authentication_callback == null
        @_subscribeAllUnsubscribedSubscriptions()
      else
        @authentication_callback.call(this)

    @websocket.onmessage = (event)=>
      data = JSON.parse(event.data)
      if data['event'] == 'Subscribed'
        @_markSubscriptionAsSubscribed(data['payload']['exchange'], data['payload']['routing_key'])
      else if data['event'] == 'Unsubscribed'
        @_removeSubscription(data['payload']['exchange_name'], data['payload']['routing_key'])
      else if data['event'] == 'Error' && data['payload']['error'] == 'SubscriptionDenied'
        @_removeSubscription(data['payload']['exchange'], data['payload']['routing_key'])
      else
        if data['mq'] && subscription = @subscriptions[Myxi.Subscription.keyFor(data['mq']['e'], data['mq']['rk'])]
          subscription._receiveMessage(data['event'], data['payload'], data['tag'])
        @_runCallbacks(data['event'], data['payload'], data['tag'], data['mq'])

      @_runCallbacks('SocketMessageReceived', data)

    @websocket.onclose = (event)=>
      if @connected
        @_runCallbacks('SocketDisconnected')
      @connected = false
      @authenticated = false
      @_markAllSubscriptionsAsUnsubscribed()
      console.log "Server disconnected."
      if @reconnect
        @reconnectTimer = setTimeout =>
          @connect()
        , 5000

    true

  disconnect: ->
    @reconnect = false
    clearTimeout(@reconnectTimer) if @reconnectTimer
    @websocket.close() if @websocket

  authentication: (callback)->
    @authentication_callback = callback

  isAuthenticated: ->
    @authenticated = true
    @_runCallbacks('SocketAuthenticated')
    @_subscribeAllUnsubscribedSubscriptions()

  sendAction: (action, payload, tag)->
    if @connected
      packet = {'action': action, 'tag': tag, 'payload': payload}
      @websocket.send(JSON.stringify(packet))
      true
    else
      false

  on: (event, callback)->
    @callbacks[event] ||= []
    @callbacks[event].push(callback)

  _runCallbacks: (event, payload, tag, mq)->
    if callbacks = @callbacks[event]
      for callback in callbacks
        callback.call(this, payload, tag, mq)

  subscribe: (exchange, routingKey)->
    if existingSubscription = @subscriptions[Myxi.Subscription.keyFor(exchange, routingKey)]
      existingSubscription
    else
      subscription = new Myxi.Subscription(this, exchange, routingKey)
      @subscriptions[subscription.key()] = subscription
      subscription

  _markSubscriptionAsSubscribed: (exchange, routingKey)->
    if subscription = @subscriptions[Myxi.Subscription.keyFor(exchange, routingKey)]
      subscription._isSubscribed()

  _removeSubscription: (exchange, routingKey)->
    key = Myxi.Subscription.keyFor(exchange, routingKey)
    if subscription = @subscriptions[key]
      subscription._isUnsubscribed()
      delete @subscriptions[key]

  _markAllSubscriptionsAsUnsubscribed: ()->
    for id, subscription of @subscriptions
      subscription._isUnsubscribed()

  _subscribeAllUnsubscribedSubscriptions: ()->
    for id, subscription of @subscriptions
      if subscription.subscribed == false && subscription.reconnect == true
        subscription.subscribe()
