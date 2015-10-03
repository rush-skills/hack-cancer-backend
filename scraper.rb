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

configure do
  enable :cross_origin
end

DOCACHING = false

get '/' do
  return "send me url please"
end

get '/*' do
  # Fetch and parse HTML document
  url = params["splat"][0].to_s
  if DOCACHING
    hash = Digest::SHA1.hexdigest(url)
    cache_file = File.join("cache",hash.to_s)
    if !File.exist?(cache_file) || (File.mtime(cache_file) < (Time.now - 3600*24*5))
      data = compute(url)
      File.open(cache_file,"w"){ |f| f << data }
    end
    send_file cache_file, :type => 'application/json'
  else
    content_type :json
    compute(url).to_json
  end

end

def compute(url)
  is_gov = check_gov(url)
  answer = JSON.parse(open(diff_it(url)).read)
  a = analyze_diff answer
  a[:is_gov] = is_gov
  {answer: a}
end


def check_gov(url)
  # puts url.split("/")[1]
  domain = url.split("/")[1].split('.')
  gov_domains = ["gov","ac","edu"]
  gov_domains.include? domain[-1] or gov_domains.include? domain[-2]
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
    score = compute_diff_score(fields)
    fields[:days_old] = score.to_i
    fields[:average_letters_per_word] = count_words(object['text'])
    return fields
  rescue

  end
end

def count_words(text)
  counter = WordsCounted.count(text)
  counter.average_chars_per_word
end

def compute_diff_score(fields)
  # puts Date.parse(fields[:date]) - Date.today
  Date.today - Date.parse(fields[:date])
end