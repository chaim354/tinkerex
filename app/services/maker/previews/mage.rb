module Maker
  module Previews
    # MillMage (`.mage`) → thumbnail PNG.
    #
    # `.mage` is MillMage's CNC project format (`<MillMageProject>` XML — the LowRider / MPCNC
    # toolchain). Like LightBurn, it embeds its own rendered preview as a base64 PNG in a
    # `<Thumbnail Source="...">` attribute, so we just extract that (Maker::Previews::EmbeddedThumbnail).
    #
    # There is deliberately NO geometry fallback: MillMage's toolpath model is a different, larger
    # parse than LightBurn's and nothing in the wild lacks the embedded thumbnail, so a file without
    # one raises NoThumbnail (-> the job marks it `failed`) rather than carrying a half-built parser.
    # Pure Ruby → `available?` is always true.
    module Mage
      module_function

      NoThumbnail = Class.new(StandardError)

      EXTENSIONS = %w[mage].freeze

      def available? = true

      def render(mage_bytes, size: 512) # rubocop:disable Lint/UnusedMethodArgument
        emb = Maker::Previews::EmbeddedThumbnail.extract(mage_bytes)
        raise NoThumbnail, "MillMage file has no embedded thumbnail" if emb.nil?

        emb
      end
    end
  end
end
