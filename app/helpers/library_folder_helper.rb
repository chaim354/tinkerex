module LibraryFolderHelper
  # THE FOLDER SENTENCE HAS THREE STATES (J, 2026-10-15), told apart by what LIBRARY_HOST_PATH
  # carries inside the container. The compose file passes it through DISPLAY-ONLY -- empty when the
  # person set nothing, so the file's own folder is the library; the path as typed when they set it
  # -- and a Kamal destination never sets it at all. This is the variable's ONE reader in app/: it
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
end
