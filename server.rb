require "net/http"
require "open-uri"
require "aws-sdk"
require "json"
require "nokogiri"
require "google/cloud/vision"
require "faraday"
require "sinatra"

class ImageDownloader
  def self.download_image(url, name="image.jpg")
    self.new.download_image(url, name)
  end

  def download_image(url, name)
    page = load_and_parse_page(url)
    image_url = extract_image_url(page)
    save_image(image_url, name)
    image_url
  end

  private

    def load_and_parse_page(url)
      user_agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_13_1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/62.0.3202.94 Safari/537.36"
      html = open(url, "User-Agent" => user_agent).read
      Nokogiri::HTML(html)
    end

    def extract_image_url(parsed_page)
      image_metatag = parsed_page.at_css("meta[property=\"og:image\"]")
      image_metatag["content"]
    end

    def save_image(url, name)
      image_data = open(url).read
      File.write("tmp/#{name}", image_data)
    end
end

class AmazonLabels
  def self.labels_for_image(path)
    new.labels_for_image(path)
  end

  def labels_for_image(path)
    rekognition = Aws::Rekognition::Client.new

    resp = rekognition.detect_labels({
      image: { bytes: File.read(path) },
      max_labels: 100,
      min_confidence: 50,
    })

    Hash[*resp.to_h[:labels].map { |l| [l[:name].downcase, l[:confidence]] }.flatten]
  end
end

class GoogleLabels
  def self.labels_for_image(path)
    new.labels_for_image(path)
  end

  def labels_for_image(path)
    vision = Google::Cloud::Vision.new
    result = vision.image(path).annotate(labels: true, web: true)

    labels = result.labels.map { |e| [e.description, e.score] }.to_h
    web_terms = result.web.entities.map { |e| [e.description.downcase, e.score/100] }.to_h

    web_terms.merge(labels).
      delete_if { |k, _| k.split(" ").size > 1 || k == "" }.
      delete_if { |_, v| v < 0.05 }.
      sort_by { |k, v| v }.
      reverse.
      to_h
  end
end

class AzureLabels
  def self.labels_for_image(path)
    new.labels_for_image(path)
  end

  def labels_for_image(path)
    conn = Faraday.new("https://westeurope.api.cognitive.microsoft.com") do |f|
      f.request :multipart
      f.request :url_encoded
      f.adapter :net_http
    end

    payload = { file: Faraday::UploadIO.new(path, "image/jpeg") }

    resp = conn.post("/vision/v1.0/tag", payload) do |req|
      req.headers["Ocp-Apim-Subscription-Key"] = ENV.fetch("AZURE_KEY")
    end

    JSON.parse(resp.body)["tags"].map { |t| [t["name"], t["confidence"]] }.to_h
  end
end

class AzureCaptions
  def self.captions_for_image(path)
    new.captions_for_image(path)
  end

  def captions_for_image(path)
    conn = Faraday.new("https://westeurope.api.cognitive.microsoft.com") do |f|
      f.request :multipart
      f.request :url_encoded
      f.adapter :net_http
    end

    payload = { file: Faraday::UploadIO.new(path, "image/jpeg") }

    resp = conn.post("/vision/v1.0/describe", payload) do |req|
      req.headers["Ocp-Apim-Subscription-Key"] = ENV.fetch("AZURE_KEY")
    end

    JSON.parse(resp.body).dig("description", "captions").map { |c| c["text"] }
  end
end

class TopTags
  def initialize(*tags)
    @tags = tags
  end

  def common_tags
    @tags.map(&:keys).reduce(:&)
  end

  def best_tags
    @tags.map(&:keys).reduce(:+).
      map { |k| scores = @tags.map { |h| h[k] }.compact; [k, scores.reduce(:+) / scores.size] }.
      to_h.
      sort_by { |_, v| v }.
      reverse.
      to_h.
      keys
  end

  def tags_for_expansion
    (common_tags + best_tags).uniq.take(4)
  end
end

class TagExpander
  def self.expand_tags(tags)
    te = new
    tags.map { |tag| te.expand_tag(tag) }.flatten
  end

  def expand_tag(tag)
    body = open("http://hashtagify.me/data/tags/#{tag}/10/6", "Referer" => "http://hashtagify.me/hashtag/landscape").read
    JSON.parse(body)[tag]["related_tags"].each_slice(2).map(&:first).take(4)
  end
end

class TagScorer
  def self.score_tags(tags)
    scores = File.readlines("top_tags.txt").map { |x| x.chomp.split(",") }.to_h
    scored = tags.map { |t| [t, scores["##{t}"].to_i] }.to_h.delete_if { |_, v| v.nil? }
    scored.sort_by { |_, v| v }.reverse.take(15).to_h
  end
end

def process(url)
  image_url = ImageDownloader.download_image(url)

  amazon = AmazonLabels.labels_for_image("tmp/image.jpg")
  google = GoogleLabels.labels_for_image("tmp/image.jpg")
  azure = AzureLabels.labels_for_image("tmp/image.jpg")

  caption = AzureCaptions.captions_for_image("tmp/image.jpg")

  tt = TopTags.new(amazon, google, azure)
  common = tt.common_tags
  best = tt.best_tags
  expanded = TagExpander.expand_tags(tt.tags_for_expansion)
  all = common + best + expanded
  most_liked = TagScorer.score_tags(all.uniq)

  {
    image: image_url,
    caption: caption,
    common: common,
    best: best,
    expanded: expanded,
    most_liked: TagScorer.score_tags((common + best + expanded).uniq),
  }
end

get "/" do
  File.read("index.html")
end

get "/api" do
  content_type :json

  if params[:url] && params[:password] == ENV.fetch("PASSWORD")
    process(params[:url]).to_json
  else
    File.read("example.json")
  end
end
