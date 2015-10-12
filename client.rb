require 'rubygems'
require 'sonos'
require 'pusher-client'
require 'excon'
require 'json'

system = Sonos::System.new # Auto-discovers the system

if system.speakers.empty?
  abort('No Sonos speaker found!')
end

speaker = system.speakers.first
p speaker

excon = Excon.new('https://slonos.herokuapp.com')

def send_data(excon, text)
  excon.post(
    :path => '/say',
    :body => URI.encode_www_form(:text => text, :client_token => CLIENT_TOKEN),
    :headers => { "Content-Type" => "application/x-www-form-urlencoded" }
  )
  # TODO error if not 200
end

APP_KEY = ENV['PUSHER_KEY']
CLIENT_TOKEN = ENV['CLIENT_TOKEN']

auth_method = lambda do |socket_id, channel|
  response = excon.post({
    :path => '/pusher_auth',
    :body => URI.encode_www_form(:socket_id => socket_id, :channel => channel.name, :client_token => CLIENT_TOKEN),
    :headers => { "Content-Type" => "application/x-www-form-urlencoded" }
  })
  decoded = JSON.parse(response.body) ## TODO validate this worked!
  decoded['auth']
end

options = {
  secure: true,
  auth_method: auth_method
}
pusher = PusherClient::Socket.new(APP_KEY, options)
pusher.subscribe('private-commands')
chan = pusher['private-commands']

# Controls

chan.bind('pause') do
  speaker.pause
end

chan.bind('play') do
  speaker.play
end

chan.bind('volume-up') do
  speaker.volume += 5
end

chan.bind('volume-down') do
  if speaker.volume > 5
    speaker.volume -= 5
  else
    speaker.volume = 0
  end
end

chan.bind('add') do |data|
  decoded = JSON.parse(data) ## TODO validate this worked!
  speaker.add_spotify_to_queue(
    {
      :id => decoded['id'], # No idea why we need that string, but otherwise we get a 800 response from Sonos
      :parent => "spotify%3aalbum%3a#{decoded['parent']}"
    }
  )
  if speaker.queue[:items].length == 1 # added the first song, play!
    speaker.play
  end
end

chan.bind('remove') do |data|
  decoded = JSON.parse(data)
  queue = speaker.queue[:items]
  if decoded.has_key?('queue_id')
    if queue.select { |track| track[:queue_id] == decoded['queue_id'] }.empty?
      # TODO Send error
    else
      speaker.remove_from_queue(decoded['queue_id'])
    end
  else
    speaker.remove_from_queue(queue.last[:queue_id])
  end
end

chan.bind('clear-queue') do
  speaker.clear_queue
end

# Queries

chan.bind('now-playing') do
  track = speaker.now_playing
  text = "#{track[:artist]} - #{track[:title]} :notes:"
  send_data(excon, text)
end

chan.bind('queue') do
  track = speaker.now_playing
  to_play = speaker.queue(track[:queue_position].to_i - 1)[:items]

  text = ''
  to_play.each_with_index do |t, i|
    text += "#{t[:artist]} - #{t[:title]}"
    if i == 0
      text += ' :notes:'
    end
    text += "\n"
  end
  send_data(excon, text)
end

pusher.connect
