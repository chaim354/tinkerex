require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Tinkerex
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # ACTIVE STORAGE VARIANTS ARE OFF, and this is a security setting, not a tuning one.
    #
    # `load_defaults 8.1` sets variant_processor = :vips, which makes Active Storage load
    # ImageProcessing::Vips -> ruby-vips at boot. This app deliberately has no ruby-vips gem: every
    # thumbnail it generates shells out to the `vipsthumbnail` BINARY (see Maker::ImageThumb and
    # the Gemfile comment), precisely so there is no in-process libvips thread pool to deadlock the
    # fork-based parallel test runner. So the variant pipeline was never usable here — it was just
    # silently inert until activestorage 8.1.3.1 (the CVE-2026-66066 fix) added an eager
    # `require "image_processing/vips"` to the transformer. That require raises a LoadError whose
    # message ("ImageProcessing::Vips requires the ruby-vips gem") matches NEITHER arm of the
    # engine's own `rescue LoadError` (/libvips/ and /image_processing/ — note the underscore),
    # so it re-raises and takes the whole boot down instead of degrading to a warning.
    #
    # :disabled is the engine's own supported answer (-> NullTransformer; its warning text names
    # it). Do NOT "fix" this by adding ruby-vips: that reintroduces the parallel-test deadlock the
    # subprocess design exists to avoid. The only `representation` call in the tree is Action
    # Text's attachment partial (app/views/active_storage/blobs/_blob.html.erb), which is
    # unreachable — both rich-text models include Maker::TextOnlyRichText, so no
    # ActionText::Attachment ever persists. Turning it off therefore removes CVE-2026-66066's
    # code path STRUCTURALLY rather than leaving it merely unreachable by argument.
    config.active_storage.variant_processor = :disabled

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
