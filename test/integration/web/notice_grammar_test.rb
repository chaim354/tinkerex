require "test_helper"

module Web
  # EVERY NOTICE AND ALERT IN ONE GRAMMAR: VERB FIRST, PAST TENSE, THE OBJECT NAMED, A FULL STOP
  # (UX audit B7 and the §H census, 2026-11-02). The app spoke two grammars side by side: 38
  # verb-first ("Deleted bracket.stl.") and 29 noun-first ("Note deleted.", "Model updated.",
  # "README saved."), so two toasts in a row read as two products. The noun-first shape is the one
  # refused here; the others are described in the plan and kept by review, because "names its
  # object" cannot be checked by a pattern.
  #
  # WHAT IS SCANNED: the string literal right after `notice:` / `alert:` (and `flash[:x] =`,
  # `flash.now[:x] =`) in app/controllers/** and app/views/**, with a `\`-continued literal joined
  # to its next line, comment lines skipped. A notice built in a method (`Maker::CreateProject::Result#notice`,
  # `publish_notice`, `project_intake_sentence`) is not a literal at the door and is not seen; those
  # were swept by hand in the same change. Devise's strings live in config/locales and are T6's.
  #
  # NOT A REQUEST TEST, deliberately: a flash is set on a redirect most tests never follow, and a
  # sentence nobody's test reaches is exactly the one that drifts.
  class NoticeGrammarTest < ActiveSupport::TestCase
    ROOTS = %w[app/controllers app/views].freeze

    # The past participles the noun-first shape ends on. Small on purpose: it is the shape the census
    # counted, not a dictionary — "Nothing selected." and "Something named x is …" are not it.
    PARTICIPLES = %w[deleted added saved removed updated created restored renamed].freeze

    # A double-quoted Ruby literal, interpolation (one level of nested braces) included.
    STRING = /"(?:[^"\\#]|\\.|\#\{(?:[^{}]|\{[^{}]*\})*\}|#)*"/
    FLASH = /(?:\b(?:notice|alert):|flash(?:\.now)?\[:(?:notice|alert)\]\s*=)\s*\(?\s*(#{STRING}(?:\s*\\\s*\n\s*#{STRING})*)/m

    # A NOUN (a capitalised word, an interpolation or a quoted name), up to three more words that are
    # not a verb of being or a negation ("is", "was", "not", "can't" make it a sentence about a
    # state, "Release not added: …"), then a participle. The first word may not itself be a past
    # tense ("Removed the tag.", "Signed out NAME.") — that is the verb-first shape this allows.
    NOT_A_LINK = /(?:not|was|were|is|are|has|have|had|been|be|can't|couldn't|cannot|won't|isn't)\b/
    NOUN_FIRST = /\A(?![A-Za-z]+ed\b)(?:[A-Z][\w.-]*|\#\{[^}]*\}|“[^”]*”)(?:\s+(?!#{NOT_A_LINK})\S+){0,3}?\s+(?:#{PARTICIPLES.join('|')})\b/

    def sources
      ROOTS.flat_map { |root| Dir[Rails.root.join(root, "**", "*.{rb,erb}").to_s] }.sort
    end

    # Ruby comment lines (never an interpolation that opens a continued line) and ERB comments.
    def code_of(path)
      src = File.read(path, encoding: "utf-8")
      src = src.gsub(/<%#.*?%>/m) { |c| "\n" * c.count("\n") } if path.end_with?(".erb")
      src.gsub(/^\s*#(?!\{).*$/, "")
    end

    def sentences
      sources.flat_map do |path|
        code_of(path).scan(FLASH).map do |(literal)|
          text = literal.scan(STRING).map { |part| part[1..-2] }.join
          [ path.delete_prefix("#{Rails.root}/"), text ]
        end
      end
    end

    test "the scan reads real notices before it is trusted" do
      found = sentences
      # §14e: a guard that scans a directory dies silently when the directory, or the spelling it
      # looks for, moves. These two are known-good literals that must keep being found.
      assert_operator found.size, :>, 50, "the scan found only #{found.size} notices — it has gone vacuous"
      texts = found.map(&:last)
      assert_includes texts, "Deleted \#{node.name}. It is in Trash."
      assert_includes texts, "Added the task “\#{task.title}”."
    end

    test "no notice or alert begins noun-first" do
      found = sentences
      assert_operator found.size, :>, 50, "the scan found only #{found.size} notices — it has gone vacuous"
      offenders = found.select { |_path, text| text.match?(NOUN_FIRST) }
      assert_empty offenders.map { |path, text| "#{path}: #{text.inspect}" },
                   "noun-first notices: say the verb first, in the past tense, and name the object " \
                   "(\"Deleted the note.\", not \"Note deleted.\")"
    end

    test "the noun-first shape is what the pattern refuses, and the verb-first one is not" do
      [ "Task deleted.", "Note added.", "README saved.", "Model updated.", "Log entry added.",
        "\#{@location.name} removed.", "Group \#{group.name} added.", "Filing rule for .\#{rule.ext} added.",
        "Folder “\#{node.name}” created." ].each do |text|
        assert_match NOUN_FIRST, text, "#{text.inspect} is noun-first and must be refused"
      end
      [ "Deleted the task “\#{title}”.", "Removed \#{label}.", "Saved the README.", "Signed out \#{device.name}.",
        "Release not added: \#{reason}.", "\#{@model.title} was removed from the catalog, so it can't be attached.",
        "Nothing selected.", "Something named \#{name} is already in this folder.", "Pinned \#{title} to the sidebar." ].each do |text|
        assert_no_match NOUN_FIRST, text, "#{text.inspect} is not the noun-first shape"
      end
    end

    test "every notice and alert ends with a full stop" do
      found = sentences
      assert_operator found.size, :>, 50, "the scan found only #{found.size} notices — it has gone vacuous"
      # A trailing interpolation is a second sentence or nothing (files_controller's `#{hint}`), so the
      # full stop that counts is the one before it.
      offenders = found.reject { |_path, text| text.rstrip.sub(/\#\{[^}]*\}\z/, "").match?(/[.?!]”?\z/) }
      assert_empty offenders.map { |path, text| "#{path}: #{text.inspect}" }, "a notice is a sentence; end it with a full stop"
    end
  end
end
