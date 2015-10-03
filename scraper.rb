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
  return "send me url plz"
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
  begin
    is_gov = check_gov(url)
    answer = JSON.parse(open(diff_it(url)).read)
    a = analyze_diff answer
    a[:is_gov] = is_gov
    flags = compute_flags a
    score = compute_score flags
    {response: {answer: a,flags: flags, score: score}}
  rescue
    {response: {score: -1}}
  end
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
      fields[:average_letters_per_word] = count_words(object['text'])[0]
      fields[:total_words] = count_words(object['text'])[1]
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
  flags[:words_flag] = data[:average_letters_per_word] > 7 if data[:average_letters_per_word]
  flags[:title_flag] = data[:title_size] > 25 if data[:title_size]
  flags[:sentiment_flag] = data[:sentiment] < -0.5 if data[:sentiment]
  flags[:text_size_flag] = data[:total_words] < 100 or data[:total_words] > 5000 if data[:total_words]
  flags[:old_flag] = data[:days_old] > 365*3 if data[:days_old]
  flags[:super_old_flag] = data[:days_old] > 365*5 if data[:days_old]
  flags[:gov_flag] = data[:is_gov]
  flags
end

def compute_score(data)
  base = 100
  base += 100 if data[:gov_flag]
  base -= 50 if data[:sentiment_flag]
  base -= 50 if data[:title_flag]
  base -= 50 if data[:words_flag]
  base -= 50 if data[:age_flag]
  base -= 50 if data[:super_old_flag]
  base -= 50 if data[:text_size_flag]
  base <= 0? 1:0
end