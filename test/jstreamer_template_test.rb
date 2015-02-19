require 'test_helper'
require 'mocha/setup'
require 'action_view'
require 'action_view/testing/resolvers'
require 'active_support/cache'
require 'jstreamer/jstreamer_template'

BLOG_POST_PARTIAL = <<-JBUILDER
  json.object! do
    json.extract! blog_post, :id, :body
    json.author do
      name = blog_post.author_name.split(nil, 2)
      json.object! do
        json.first_name name[0]
        json.last_name  name[1]
      end
    end
  end
JBUILDER

COLLECTION_PARTIAL = <<-JBUILDER
  json.object! do
    json.extract! collection, :id, :name
  end
JBUILDER

CACHE_KEY_PROC = Proc.new { |blog_post| true }

BlogPost = Struct.new(:id, :body, :author_name)
Collection = Struct.new(:id, :name)
blog_authors = [ 'David Heinemeier Hansson', 'Pavel Pravosud' ].cycle
BLOG_POST_COLLECTION = 10.times.map{ |i| BlogPost.new(i+1, "post body #{i+1}", blog_authors.next) }
COLLECTION_COLLECTION = 5.times.map{ |i| Collection.new(i+1, "collection #{i+1}") }

ActionView::Template.register_template_handler :jstreamer, JstreamerHandler

module Rails
  def self.cache
    @cache ||= ActiveSupport::Cache::MemoryStore.new
  end
end

class JstreamerTemplateTest < ActionView::TestCase
  setup do
    @context = self
    Rails.cache.clear
  end

  def partials
    {
      '_partial.json.jstreamer'  => 'json.object! { json.content "hello" }',
      '_blog_post.json.jstreamer' => BLOG_POST_PARTIAL,
      '_collection.json.jstreamer' => COLLECTION_PARTIAL
    }
  end

  def render_jstreamer(source)
    @rendered = []
    lookup_context.view_paths = [ActionView::FixtureResolver.new(partials.merge('test.json.jstreamer' => source))]
    ActionView::Template.new(source, 'test', JstreamerHandler, :virtual_path => 'test').render(self, {}).strip
  end

  def undef_context_methods(*names)
    self.class_eval do
      names.each do |name|
        undef_method name.to_sym if method_defined?(name.to_sym)
      end
    end
  end

  def assert_collection_rendered(json, context = nil)
    result = Wankel.load(json)
    result = result.fetch(context) if context

    assert_equal 10, result.length
    assert_equal Array, result.class
    assert_equal 'post body 5',        result[4]['body']
    assert_equal 'Heinemeier Hansson', result[2]['author']['last_name']
    assert_equal 'Pavel',              result[5]['author']['first_name']
  end

  test 'rendering' do
    json = render_jstreamer <<-JBUILDER
      json.object! do
        json.content 'hello'
      end
    JBUILDER

    assert_equal 'hello', Wankel.load(json)['content']
  end

  test 'key_format! with parameter' do
    json = render_jstreamer <<-JBUILDER
      json.object! do
        json.key_format! :camelize => [:lower]
        json.camel_style 'for JS'
      end
    JBUILDER

    assert_equal ['camelStyle'], Wankel.load(json).keys
  end

  test 'key_format! propagates to child elements' do
    json = render_jstreamer <<-JBUILDER
      json.object! do
        json.key_format! :upcase
        json.level1 'one'
        json.level2 do
          json.object! do
            json.value 'two'
          end
        end
      end
    JBUILDER

    result = Wankel.load(json)
    assert_equal 'one', result['LEVEL1']
    assert_equal 'two', result['LEVEL2']['VALUE']
  end

  test 'partial! renders partial' do
    json = render_jstreamer <<-JBUILDER
      json.partial! 'partial'
    JBUILDER

    assert_equal 'hello', Wankel.load(json)['content']
  end

  test 'partial! renders collections' do
    json = render_jstreamer <<-JBUILDER
      json.partial! 'blog_post', :collection => BLOG_POST_COLLECTION, :as => :blog_post
    JBUILDER

    assert_collection_rendered json
  end

  test 'partial! renders collections when as argument is a string' do
    json = render_jstreamer <<-JBUILDER
      json.partial! 'blog_post', collection: BLOG_POST_COLLECTION, as: "blog_post"
    JBUILDER

    assert_collection_rendered json
  end

  test 'partial! renders collections as collections' do
    json = render_jstreamer <<-JBUILDER
      json.partial! 'collection', collection: COLLECTION_COLLECTION, as: :collection
    JBUILDER

    assert_equal 5, Wankel.load(json).length
  end

  test 'partial! renders as empty array for nil-collection' do
    json = render_jstreamer <<-JBUILDER
      json.partial! 'blog_post', :collection => nil, :as => :blog_post
    JBUILDER

    assert_equal '[]', json
  end

  test 'partial! renders collection (alt. syntax)' do
    json = render_jstreamer <<-JBUILDER
      json.partial! :partial => 'blog_post', :collection => BLOG_POST_COLLECTION, :as => :blog_post
    JBUILDER

    assert_collection_rendered json
  end

  test 'partial! renders as empty array for nil-collection (alt. syntax)' do
    json = render_jstreamer <<-JBUILDER
      json.partial! :partial => 'blog_post', :collection => nil, :as => :blog_post
    JBUILDER

    assert_equal '[]', json
  end

  test 'render array of partials' do
    json = render_jstreamer <<-JBUILDER
      json.array! BLOG_POST_COLLECTION, :partial => 'blog_post', :as => :blog_post
    JBUILDER

    assert_collection_rendered json
  end

  test 'render array of partials as empty array with nil-collection' do
    json = render_jstreamer <<-JBUILDER
      json.array! nil, :partial => 'blog_post', :as => :blog_post
    JBUILDER

    assert_equal '[]', json
  end

  test 'render array if partials as a value' do
    json = render_jstreamer <<-JBUILDER
      json.object! do
        json.posts BLOG_POST_COLLECTION, :partial => 'blog_post', :as => :blog_post
      end
    JBUILDER

    assert_collection_rendered json, 'posts'
  end

  test 'render as empty array if partials as a nil value' do
    json = render_jstreamer <<-JBUILDER
      json.object! do
        json.posts nil, :partial => 'blog_post', :as => :blog_post
      end
    JBUILDER

    assert_equal '{"posts":[]}', json
  end

  test 'fragment caching a JSON object' do
    undef_context_methods :fragment_name_with_digest, :cache_fragment_name

    render_jstreamer <<-JBUILDER
      json.object! do
        json.cache! 'cachekey' do
          json.name 'Cache'
        end
      end
    JBUILDER

    json = render_jstreamer <<-JBUILDER
      json.object! do
        json.cache! 'cachekey' do
          json.name 'Miss'
        end
      end
    JBUILDER

    parsed = Wankel.load(json)
    assert_equal 'Cache', parsed['name']
  end

  test 'conditionally fragment caching a JSON object' do
    undef_context_methods :fragment_name_with_digest, :cache_fragment_name

    render_jstreamer <<-JBUILDER
      json.object! do
        json.cache_if! true, 'cachekey' do
          json.test1 'Cache'
        end
        json.cache_if! false, 'cachekey' do
          json.test2 'Cache'
        end
      end
    JBUILDER

    json = render_jstreamer <<-JBUILDER
      json.object! do
        json.cache_if! true, 'cachekey' do
          json.test1 'Miss'
        end
        json.cache_if! false, 'cachekey' do
          json.test2 'Miss'
        end
      end
    JBUILDER

    parsed = Wankel.load(json)
    assert_equal 'Cache', parsed['test1']
    assert_equal 'Miss', parsed['test2']
  end

  test 'fragment caching deserializes an array' do
    undef_context_methods :fragment_name_with_digest, :cache_fragment_name

    json = render_jstreamer <<-JBUILDER
      json.cache! 'cachekey' do
        json.array! %w[a b c]
      end
    JBUILDER

    # cache miss output correct
    assert_equal %w[a b c], Wankel.load(json)

    json = render_jstreamer <<-JBUILDER
      json.cache! 'cachekey' do
        json.array! %w[1 2 3]
      end
    JBUILDER

    # cache hit output correct
    assert_equal %w[a b c], Wankel.load(json)
  end

  test 'fragment caching works with previous version of cache digests' do
    undef_context_methods :cache_fragment_name

    @context.expects :fragment_name_with_digest

    render_jstreamer <<-JBUILDER
      json.cache! 'cachekey' do
        json.name 'Cache'
      end
    JBUILDER
  end

  test 'fragment caching works with current cache digests' do
    undef_context_methods :fragment_name_with_digest

    @context.expects :cache_fragment_name
    ActiveSupport::Cache.expects :expand_cache_key

    render_jstreamer <<-JBUILDER
      json.cache! 'cachekey' do
        json.name 'Cache'
      end
    JBUILDER
  end

  test 'current cache digest option accepts options' do
    undef_context_methods :fragment_name_with_digest

    @context.expects(:cache_fragment_name).with('cachekey', skip_digest: true)
    ActiveSupport::Cache.expects :expand_cache_key

    render_jstreamer <<-JBUILDER
      json.cache! 'cachekey', skip_digest: true do
        json.name 'Cache'
      end
    JBUILDER
  end

  test 'does not perform caching when controller.perform_caching is false' do
    controller.perform_caching = false
    render_jstreamer <<-JBUILDER
      json.cache! 'cachekey' do
        json.name 'Cache'
      end
    JBUILDER

    assert_equal Rails.cache.inspect[/entries=(\d+)/, 1], '0'
  end

  test 'renders cached array of block partials' do
    undef_context_methods :fragment_name_with_digest, :cache_fragment_name

    json = render_jstreamer <<-JBUILDER
      json.cache_collection! BLOG_POST_COLLECTION do |blog_post|
        json.partial! 'blog_post', :blog_post => blog_post
      end
    JBUILDER

    assert_collection_rendered json
  end

  test 'renders cached array with a key specified as a proc' do
    undef_context_methods :fragment_name_with_digest, :cache_fragment_name
    CACHE_KEY_PROC.expects(:call)

    json = render_jstreamer <<-JBUILDER
      json.cache_collection! BLOG_POST_COLLECTION, key: CACHE_KEY_PROC do |blog_post|
        json.partial! 'blog_post', :blog_post => blog_post
      end
    JBUILDER

    assert_collection_rendered json
  end

  test 'reverts to cache! if cache does not support fetch_multi' do
    undef_context_methods :fragment_name_with_digest, :cache_fragment_name
    ActiveSupport::Cache::Store.send(:undef_method, :fetch_multi) if ActiveSupport::Cache::Store.method_defined?(:fetch_multi)

    json = render_jstreamer <<-JBUILDER
      json.cache_collection! BLOG_POST_COLLECTION do |blog_post|
        json.partial! 'blog_post', :blog_post => blog_post
      end
    JBUILDER

    assert_collection_rendered json
  end

  test 'reverts to array! when controller.perform_caching is false' do
    controller.perform_caching = false

    json = render_jstreamer <<-JBUILDER
      json.cache_collection! BLOG_POST_COLLECTION do |blog_post|
        json.partial! 'blog_post', :blog_post => blog_post
      end
    JBUILDER

    assert_collection_rendered json
  end
  
end