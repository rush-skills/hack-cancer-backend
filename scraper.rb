require 'rubygems'
require 'puma'
require 'sinatra'
require 'spreadsheet'
require 'json'
require 'selenium-webdriver'
require 'nokogiri'
require 'open-uri'
require 'digest/sha1'
require 'words_counted'
require 'sinatra/cross_origin'
require 'mongo'
require 'json/ext'
require 'twilio-ruby'

configure do
  enable :cross_origin
  set :sms, false
  set :caching, true
  set :twilio_sid, ENV['TWILIO_SID']
  set :twilio_token, ENV['TWILIO_TOKEN']
  db = Mongo::Client.new([ '127.0.0.1:27017' ], :database => 'hackcancer')
  set :mongo_db, db[:hackcancer]
  db[:hackcancer].indexes.create_one({:url => 1}, :unique => true)
end

get '/' do
  return "send me url plz"
end

get '/*' do
  content_type :json
  # Fetch and parse HTML document
  url = params["splat"][0].to_s
  if settings.caching
    documents = settings.mongo_db.find(:url => url)
    if !documents.to_a.first.nil?
      return documents.to_a.first[:data]
    else
      data = compute(url).to_json
      if data['response']['score'] != -1
        settings.mongo_db.insert_one({url: url,data: data, score: data['response']['score']})
      end
      return data
    end
  else
    compute(url).to_json
  end
end

def compute(url)
  begin
    answer = JSON.parse(open(diff_it(url)).read)
    a = analyze_diff answer
    a[:is_gov] = check_gov(url)
    a[:whitelist] = check_whitelist(url)
    a[:blacklist] = check_blacklist(url)
    flags = compute_flags a
    score = compute_score flags
    twilio_noti if score == 1 && settings.sms
    {response: {answer: a,flags: flags, score: score}}
  rescue
    {response: {score: -1}}
  end
end

def check_whitelist(url)
  ["http://google.com"].any? { |white| url.include? white}
end

def check_blacklist(url)
  ["www.quackwatch.org","www.aaets.org","www.doctoryourself.com"].any? { |black| url.include? black}
end

def check_gov(url)
  # puts url.split("/")[1]
  begin
    domain = url.split("/")[1].split('.')
    gov_domains = ["gov","ac","edu"]
    gov_domains.include? domain[-1] or gov_domains.include? domain[-2]
  rescue
    false
  end
end

def diff_it(url)
  diff_bot_uri = "http://api.diffbot.com/v3/analyze?token="
  diff_bot_token = "2cef8aae35e85b9639e7f2b66d6faa5c"

  diff_bot_uri + diff_bot_token + "&url="+url + "&fields=sentiment,links,meta"
end

def analyze_diff(data)
  begin
    object = data['objects'][0]
    fields = {sentiment: object['sentiment'], text: object['text'], date: object['date'], estimated_date: object['estimatedDate'],title: object['title'], title_size: object['title'].split(' ').count, author: object['author']}
    fields.default = nil
    if fields[:date]
      score = compute_diff_score(fields)
      fields[:days_old] = score.to_i
    end
    if fields[:text]
      temp = count_words(object['text'])
      fields[:average_letters_per_word] = temp[0]
      fields[:total_words] = temp[1]
    end
    return fields
  rescue

  end
end

def count_words(text)
  counter = WordsCounted.count(text)
  [counter.average_chars_per_word,counter.word_count]
end

def compute_diff_score(fields)
  Date.today - Date.parse(fields[:date])
end

def compute_flags(data)
  flags = Hash.new(false)
  flags[:words_flag] = data[:average_letters_per_word] > 6 if data[:average_letters_per_word]
  flags[:title_flag] = data[:title_size] > 20 if data[:title_size]
  flags[:sentiment_flag] = data[:sentiment] < -0.4 if data[:sentiment]
  flags[:text_size_flag] = data[:total_words] < 100 || data[:total_words] > 5000
  flags[:old_flag] = data[:days_old] > 365*1 if data[:days_old]
  flags[:super_old_flag] = data[:days_old] > 365*3 if data[:days_old]
  flags[:gov_flag] = data[:is_gov]
  flags[:whitelist] = data[:whitelist]
  flags[:blacklist] = data[:blacklist]
  flags
end

def compute_score(data)
  base = 100
  base += 100 if data[:gov_flag]
  base -= 50 if data[:sentiment_flag]
  base -= 50 if data[:title_flag]
  base -= 50 if data[:words_flag]
  base -= 50 if data[:old_flag]
  base -= 50 if data[:super_old_flag]
  base -= 50 if data[:text_size_flag]
  base += 1000 if data[:whitelist]
  base -= 1000 if data[:blacklist]
  base <= 0? 1:0
end

def twilio_noti
  # set up a client to talk to the Twilio REST API
  account_sid = settings.twilio_sid
  auth_token = settings.twilio_token
  @client = Twilio::REST::Client.new account_sid, auth_token

  @client.account.messages.create({
    :from => '(617) 925-6342',
    :to => '8579288498',
    :body => 'The patient is trying to visit a site flagged dangerous by us.',
  })
end

# ---------MONGO DB METHODS ------------

helpers do
  # a helper method to turn a string ID
  # representation into a BSON::ObjectId
  def object_id val
    begin
      BSON::ObjectId.from_string(val)
    rescue BSON::ObjectId::Invalid
      nil
    end
  end

  def document_by_id id
    id = object_id(id) if String === id
    if id.nil?
      {}.to_json
    else
      document = settings.mongo_db.find(:_id => id).to_a.first
      (document || {}).to_json
    end
  end
end
