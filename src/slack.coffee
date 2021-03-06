{Robot, Adapter, EnterMessage, LeaveMessage, TopicMessage} = require 'hubot'
{SlackTextMessage, SlackRawMessage, SlackBotMessage} = require './message'
{SlackRawListener, SlackBotListener} = require './listener'

SlackClient = require 'slack-client'
Util = require 'util'

class SlackBot extends Adapter
  @MAX_MESSAGE_LENGTH: 8000
  @MIN_MESSAGE_LENGTH: 1

  constructor: (robot) ->
    @robot = robot

  run: ->
    # Take our options from the environment, and set otherwise suitable defaults
    options =
      token: process.env.HUBOT_SLACK_TOKEN
      autoReconnect: true
      autoMark: true

    return @robot.logger.error "No services token provided to Hubot" unless options.token
    return @robot.logger.error "v2 services token provided, please follow the upgrade instructions" unless (options.token.substring(0, 5) in ['xoxb-', 'xoxp-'])

    @options = options

    # Create our slack client object
    @client = new SlackClient options.token, options.autoReconnect, options.autoMark

    # Setup event handlers
    # TODO: Handle eventual events at (re-)connection time for unreads and provide a config for whether we want to process them
    @client.on 'error', @.error
    @client.on 'loggedIn', @.loggedIn
    @client.on 'open', @.open
    @client.on 'close', @.clientClose
    @client.on 'message', @.message
    @client.on 'userChange', @.userChange
    @robot.brain.on 'loaded', @.brainLoaded

    @robot.on 'slack-attachment', @.customMessage
    @robot.on 'slack.attachment', @.customMessage

    # Start logging in
    @client.login()

  error: (error) =>
    return @robot.logger.warning "Received rate limiting error #{JSON.stringify error}" if error.code == -1

    @robot.emit 'error', error

  loggedIn: (self, team) =>
    @robot.logger.info "Logged in as #{self.name} of #{team.name}, but not yet connected"

    # store a copy of our own user data
    @self = self

    # Provide our name to Hubot
    @robot.name = self.name

    for id, user of @client.users
      @userChange user

  brainLoaded: =>
    # once the brain has loaded, reload all the users from the client
    for id, user of @client.users
      @userChange user

    # also wipe out any broken users stored under usernames instead of ids
    for id, user of @robot.brain.data.users
      if id is user.name then delete @robot.brain.data.users[user.id]

  userChange: (user) =>
    return unless user?.id?
    newUser =
      name: user.name
      real_name: user.real_name
      email_address: user.profile?.email
      slack: {}
    for key, value of user
      # user contains an of the SlackClient, which and contains references to the all the data types (users, channels) plus things like the token, s
      # so, don't bother storing it
      continue if value instanceof SlackClient
      newUser.slack[key] = value

    if user.id of @robot.brain.data.users

      for key, value of @robot.brain.data.users[user.id]
        unless key of newUser
          newUser[key] = value
    delete @robot.brain.data.users[user.id]
    @robot.brain.userForId user.id, newUser

  open: =>
    @robot.logger.info 'Slack client now connected'

    # Tell Hubot we're connected so it can load scripts
    @emit "connected"

  clientClose: =>
    # Don't actually do anything since we may reconnect in the future
    @robot.logger.info 'Slack client closed, waiting for reconnect'

  message: (msg) =>
    # Ignore our own messages
    return if msg.user == @self.id

    channel = @client.getChannelGroupOrDMByID msg.channel if msg.channel

    if msg.hidden or (not msg.text and not msg.attachments) or msg.subtype is 'bot_message' or not msg.user or not channel
      # use a raw message, so scripts that care can still see these things

      if msg.user
        user = @robot.brain.userForId msg.user
      else
        # We need to fake a user because, at the very least, CatchAllMessage
        # expects it to be there.
        user = {}
        user.name = msg.username if msg.username?
      user.room = channel.name if channel

      rawText = msg.getBody()
      text = @removeFormatting rawText

      if msg.subtype is 'bot_message'
        @robot.logger.debug "Received bot message: '#{text}' in channel: #{channel?.name}, from: #{user?.name}"
        @receive new SlackBotMessage user, text, rawText, msg
      else
        @robot.logger.debug "Received raw message (subtype: #{msg.subtype})"
        @receive new SlackRawMessage user, text, rawText, msg
      return

    # Process the user into a full hubot user
    user = @robot.brain.userForId msg.user
    user.room = channel.name

    # Test for enter/leave messages
    if msg.subtype is 'channel_join' or msg.subtype is 'group_join'
      @robot.logger.debug "#{user.name} has joined #{channel.name}"
      @receive new EnterMessage user

    else if msg.subtype is 'channel_leave' or msg.subtype is 'group_leave'
      @robot.logger.debug "#{user.name} has left #{channel.name}"
      @receive new LeaveMessage user

    else if msg.subtype is 'channel_topic' or msg.subtype is 'group_topic'
      @robot.logger.debug "#{user.name} set the topic in #{channel.name} to #{msg.topic}"
      @receive new TopicMessage user, msg.topic, msg.ts

    else
      # Build message text to respond to, including all attachments
      rawText = msg.getBody()
      text = @removeFormatting rawText

      @robot.logger.debug "Received message: '#{text}' in channel: #{channel.name}, from: #{user.name}"

      # If this is a DM, pretend it was addressed to us
      if msg.getChannelType() == 'DM'
        text = "#{@robot.name} #{text}"

      @receive new SlackTextMessage user, text, rawText, msg

  removeFormatting: (text) ->
    # https://api.slack.com/docs/formatting
    text = text.replace ///
      <              # opening angle bracket
      ([@#!])?       # link type
      ([^>|]+)       # link
      (?:\|          # start of |label (optional)
        ([^>]+)      # label
      )?             # end of label
      >              # closing angle bracket
    ///g, (m, type, link, label) =>

      switch type

        when '@'
          if label then return label
          user = @client.getUserByID link
          if user
            return "@#{user.name}"

        when '#'
          if label then return label
          channel = @client.getChannelByID link
          if channel
            return "\##{channel.name}"

        when '!'
          if link in ['channel','group','everyone']
            return "@#{link}"

        else
          link = link.replace /^mailto:/, ''
          if label and -1 == link.indexOf label
            "#{label} (#{link})"
          else
            link
    text = text.replace /&lt;/g, '<'
    text = text.replace /&gt;/g, '>'
    text = text.replace /&amp;/g, '&'
    text

  send: (envelope, messages...) ->
    channel = @client.getChannelGroupOrDMByName envelope.room

    if not channel and @client.getUserByName(envelope.room)
      user_id = @client.getUserByName(envelope.room).id
      @client.openDM user_id, =>
        this.send envelope, messages...
      return

    for msg in messages
      continue if msg.length < SlackBot.MIN_MESSAGE_LENGTH

      if msg.length > SlackBot.MAX_MESSAGE_LENGTH
        @robot.logger.warning "Tried to send #{msg.length} character message, which is bigger than Slack's #{SlackBot.MAX_MESSAGE_LENGTH} maximum: truncating it"

        msg = msg.substring(0, SlackBot.MAX_MESSAGE_LENGTH)

      # Bots cannot display images from files.slack.com in images, as all
      # images will be accessed anonymously.
      attachment = if (msg.match(/^https?:\/\/\S+\.(?:jpg|jpe|jpeg|png|gif|bmp|dib)/) or
                   msg.match(/^https?:\/\/images.duckduckgo.com\//)) and
                   !msg.match(/https:\/\/files\.slack\.com/)
        @robot.logger.debug "Sending to #{envelope.room} as image: #{msg}"
        {image_url: msg, fallback: msg}
      else
        @robot.logger.debug "Sending to #{envelope.room}: #{msg}"
        {text: msg, mrkdwn_in: ['text'], fallback: msg}

      @customMessage channel: envelope.room, attachments: attachment

  reply: (envelope, messages...) ->
    @robot.logger.debug "Sending reply"

    for msg in messages
      # TODO: Don't prefix username if replying in DM
      @send envelope, "#{envelope.user.name}: #{msg}"

  topic: (envelope, strings...) ->
    channel = @client.getChannelGroupOrDMByName envelope.room
    channel.setTopic strings.join "\n"

  customMessage: (data) =>

    channelName = if data.channel
      data.channel
    else if data.message.envelope
      data.message.envelope.room
    else data.message.room

    channel = @client.getChannelGroupOrDMByName channelName
    return unless channel

    msg = {}
    msg.attachments = data.attachments || data.content
    msg.attachments = [msg.attachments] unless Array.isArray msg.attachments

    msg.text = data.text

    if data.username && data.username != @robot.name
      msg.as_user = false
      msg.username = data.username
      if data.icon_url?
        msg.icon_url = data.icon_url
      else if data.icon_emoji?
        msg.icon_emoji = data.icon_emoji
    else
      msg.as_user = true

    channel.postMessage msg

# Export class for unit tests
module.exports = SlackBot
