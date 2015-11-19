require 'sinatra'
require 'json'
require 'octokit'
require 'redis'

# Constants
ACCESS_TOKEN = ENV['ACCESS_TOKEN']
REDIS_URI = ENV["REDISTOGO_URL"] || 'redis://localhost:6379'
SECRET_TOKEN = ENV['SECRET_TOKEN']
NEEDED_PLUS_ONES = 2
PLUS_ONE_COMMENT = ':+1:'
NEG_ONE_COMMENT = ':-1:'

# Setup our clients
before do
  uri = URI.parse(REDIS_URI)
  @redis = Redis.new(:host => uri.host, :port => uri.port, :password => uri.password)
  @client ||= Octokit::Client.new(:access_token => ACCESS_TOKEN)
end

# Webhook endpoint
# TODO persist data via postgres
post '/hooks' do
  # Grab our payload
  request.body.rewind
  payload_body = request.body.read

  # Verify our signature is coming from Github
  verify_signature(payload_body)

  @payload = JSON.parse(payload_body)

  # If $required_plus_ones has been specified, change the default
  if params['required_plus_ones'].to_i > 0
    NEEDED_PLUS_ONES = params['required_plus_ones'].to_i
  end

  # A webhook has been received from Github
  case request.env['HTTP_X_GITHUB_EVENT']
  when "pull_request"
    if @payload["action"] == "opened" || @payload["action"] == "synchronize"
      process_opened_pull_request(@payload["pull_request"])
    elsif @payload["action"] == "closed"
      process_closed_pull_request(@payload["pull_request"])
    end
  when "issue_comment"
    if @payload["action"] == "created"
      process_created_issue_comment(@payload)
    end
  end
end

# Helper methods
helpers do

  # A pull request has been opened for a particular repo
  def process_opened_pull_request(pull_request)
    pr_name = pull_request['base']['repo']['full_name'].to_s
    pr_number = pull_request['number'].to_s
    pr_key = pr_name + ":" + pr_number
    commit_hash = pull_request['head']['sha'].to_s
    creator = pull_request['base']['user']['id'].to_s

    # Initialize the dataset
    payload_to_store = {
      :plus_one_count => 0,
      :authors => [],
      :creator => creator,
    }

    @redis.hset(pr_key, commit_hash, payload_to_store.to_json)

    # Set the PR status to be pending
    @client.create_status(
      pr_name,
      commit_hash,
      'pending',
      {
        'description' => 'Required plus ones (0/' + NEEDED_PLUS_ONES.to_s + ') has yet to be reached.',
        'context' => 'code review'
      }
    )
    return 200
  end

  # A pull request has been closed
  def process_closed_pull_request(pull_request)
    pr_name = pull_request['base']['repo']['full_name'].to_s
    pr_number = pull_request['number'].to_s
    pr_key = pr_name + ":" + pr_number
    current_commit_hash = pull_request['head']['sha'].to_s

    # Delete the PR from the redis store
    @redis.del(pr_key)
    return 200
  end

  # An issue comment has been reported
  def process_created_issue_comment(issue_comment_payload)
    pr_name = issue_comment_payload['repository']['full_name'].to_s
    pr_number = issue_comment_payload['issue']['number'].to_s
    pr_key = pr_name + ":" + pr_number

    pull_request = @client.pull_request(pr_name, pr_number)
    current_commit_hash = pull_request['head']['sha'].to_s

    # Grab the stored payload
    stored_payload_value = @redis.hget(pr_key, current_commit_hash)

    # Ensure that a key actually exists
    if !stored_payload_value.nil?
      stored_payload = JSON.parse(stored_payload_value)
      plus_ones = stored_payload['plus_one_count'].to_i
      authors = stored_payload['authors']
      creator = stored_payload['creator'].to_s

      comment_user = issue_comment_payload['comment']['user']['id'].to_s
      # Check if the commenting user is the creator or has already commented
      is_comment_user_creator_or_author = authors.include?(comment_user) || creator === comment_user

      plus_ones_to_add = is_comment_user_creator_or_author ? 0 : parse_comment_body(issue_comment_payload['comment']['body'])

      # If there is no net change
      if plus_ones_to_add === 0
        return 200
      end

      plus_ones = plus_ones + plus_ones_to_add

      # Ensure the count isn't negative
      if plus_ones < 0
        plus_ones = 0
      end

      # Update authors list
      if !authors.include?(comment_user)
        authors.push(comment_user)
      end

      payload_to_store = {
        :plus_one_count => plus_ones,
        :authors => authors,
        :creator => creator,
      }

      # Store the new payload data
      @redis.hset(pr_key, current_commit_hash, payload_to_store.to_json)

      if plus_ones >= NEEDED_PLUS_ONES
        # Set commit status to sucessful
        @client.create_status(
          pr_name,
          current_commit_hash,
          'success',
          {
            'description' => 'Required plus ones (' + plus_ones.to_s + '/' + NEEDED_PLUS_ONES.to_s + ') has been reached!',
            'context' => 'code review'
          }
        )
      else
        @client.create_status(
          pr_name,
          current_commit_hash,
          'pending',
          {
            'description' => 'Required plus ones (' + plus_ones.to_s + '/' + NEEDED_PLUS_ONES.to_s + ') has yet to be reached.',
            'context' => 'code review'
          }
        )
      end
    end

    return 200
  end

  # Simply parse the comment for plus ones
  def parse_comment_body(comment_body)
    # Ignore common markdown prefixes
    comment_body = comment_body.gsub(/^(>\s|\#{1,4}\s|\*\s|\+\s|-\s).+/s, '')

    plus_one_regex_pattern = Regexp.new('(' + Regexp.escape(PLUS_ONE_COMMENT) + ')')
    neg_one_regex_pattern = Regexp.new('(' + Regexp.escape(NEG_ONE_COMMENT) + ')')

    total_plus = comment_body.scan(plus_one_regex_pattern).count
    total_neg = comment_body.scan(neg_one_regex_pattern).count
    net_pluses = total_plus - total_neg

    if net_pluses > 0
      net_pluses = 1
    elsif net_pluses < 0
      net_pluses = -1
    end

    return net_pluses
  end

  # Ensure the delivered webhook is from Github
  def verify_signature(payload_body)
    signature = 'sha1=' + OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), SECRET_TOKEN, payload_body)
    return halt 500, "Signatures didn't match!" unless Rack::Utils.secure_compare(signature, request.env['HTTP_X_HUB_SIGNATURE'])
  end
end
