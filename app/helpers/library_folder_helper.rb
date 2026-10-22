module LibraryFolderHelper
  # THE FOLDER SENTENCE HAS THREE STATES (J, 2026-10-15), told apart by what LIBRARY_HOST_PATH
  # carries inside the container. The compose file passes it through DISPLAY-ONLY -- empty when the
  # person set nothing, so the file's own folder is the library; the path as typed when they set it
  # -- and a Kamal destination never sets it at all. This module is the variable's ONE reader in app/: it
  # must never become a path the process opens, because a wrong value here can only mislead a
  # sentence, which is the whole reason it is allowed to come from the person unchecked.
  # `tag.code` escapes the value: it is shown as typed, never interpreted.
  def library_folder_label
    value = ENV["LIBRARY_HOST_PATH"]
    return "The library folder on the server" if value.nil?

    value = value.strip
    return safe_join([ "The folder your ", tag.code("docker-compose.yml"), " is in" ]) if value.empty?

    tag.code(value)
  end

  # THE SAME THREE STATES AS PLAIN TEXT (K), for the folder chooser's root label, which is an
  # attribute and cannot carry markup. Escaped by the attribute it lands in, never interpreted.
  def library_folder_text
    value = ENV["LIBRARY_HOST_PATH"]
    return "The library folder on the server" if value.nil?
    return "The folder your docker-compose.yml is in" if value.strip.empty?

    value.strip
  end

  # THE LIBRARY AS IT IS NOW (K, 2026-10-20): the mount's label, plus the folder chosen inside it
  # when one is (Tinkerex::LibraryRoot). A typed host path reads as one path; the other two labels
  # are prose, so the chosen folder follows them. Still display-only: the joined path is a sentence,
  # and nothing opens it.
  def library_root_label(relative = Tinkerex::LibraryRoot.relative)
    return library_folder_label if relative.blank?

    host = ENV["LIBRARY_HOST_PATH"].to_s.strip
    return tag.code("#{host.chomp('/')}/#{relative}") if host.present?

    safe_join([ library_folder_label, ", in its folder ", tag.code(relative) ])
  end
end
