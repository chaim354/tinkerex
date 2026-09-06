require "test_helper"

module Web
  # THE LAZY BUNDLES MUST NOT BE MODULE-PRELOADED. The CodeMirror bundle, its two companion
  # modules, the KiCanvas bundle and the tracespace bundle are dynamic-imported by their Stimulus
  # controllers so that no page pays for them until a text, KiCad or Gerber file is actually opened
  # -- config/importmap.rb
  # says so at each pin. importmap-rails 2.x quietly undoes that: every pin is emitted as
  # <link rel="modulepreload"> by default, and a preload hint makes the browser FETCH the module on
  # every page whatever imports it. Measured on the dev server before the fix: kicanvas.js (477 KB)
  # and codemirror.js in the sign-in page's preload set. `preload: false` on the pin is the opt-out,
  # and this drives a real page so the assertion is about what a browser receives, not the config.
  class LazyBundlesTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    # `online-3d-viewer` IS THE LARGEST OF THEM (1.0 MB, 274 KB gzipped) and therefore the one this
    # test earns the most on: modelviewer_controller.js imports it only when the user clicks
    # "View in 3D", so even a page holding a `.stl` must not fetch it.
    #
    # THE BASENAME IS `o3dv`, NOT THE PIN NAME — the check below derives the digested href from
    # `File.basename(name)`, and this pin maps the specifier "online-3d-viewer" to the file
    # "o3dv.js". Listed here with its FILE name so the preload lookup finds the right asset; the
    # importmap-entry half of the assertion needs the SPECIFIER, so the two are a pair.
    LAZY = { "kicanvas" => "kicanvas", "tracespace" => "tracespace", "codemirror" => "codemirror",
             "lib/codemirror_languages" => "codemirror_languages",
             "lib/codemirror_theme" => "codemirror_theme",
             "online-3d-viewer" => "o3dv" }.freeze

    setup do
      @user = User.create!(email: "lazy-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    test "the lazily imported bundles are pinned but not module-preloaded" do
      get projects_path
      assert_response :success

      preloads = css_select("link[rel=modulepreload]").map { |link| link["href"] }
      # NON-VACUOUS: the page must preload its ORDINARY modules, or "none of the lazy ones" is
      # true of a page that preloads nothing at all (§14e's empty-set guard).
      assert_operator preloads.size, :>, 5, "expected the ordinary modules to be preloaded, found #{preloads.size}"

      imports = JSON.parse(css_select("script[type=importmap]").first.text).fetch("imports")
      LAZY.each do |name, basename|
        assert imports.key?(name), "#{name} lost its importmap entry -- preload: false is not unpin"
        digested = "/#{basename}-"
        offenders = preloads.select { |href| href.include?(digested) }
        assert_empty offenders, "#{name} is module-preloaded on every page: #{offenders}"
      end
    end
  end
end
