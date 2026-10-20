namespace :maker do
  # THE DAILY ROLE SWEEP, NOW. config/recurring.yml runs Maker::ClassifyAttachmentRolesJob every day;
  # this is the same run for the one moment its whole backlog arrives together, right after a deploy
  # that widened Maker::FileAttachment::ROLE_BY_EXT. Nothing to dry-run: it only rewrites a row
  # stored `other` to the role the vocabulary now gives its name, which is what an attach door
  # would write for that file today.
  desc "Give every attachment stored as `other` the role ROLE_BY_EXT now names for its file " \
       "(the daily sweep, run now)"
  task classify_roles: :environment do
    n = Maker::ClassifyAttachmentRolesJob.perform_now
    puts "Classified #{n} attachment role(s) stored as other that the vocabulary now names."
  end
end
