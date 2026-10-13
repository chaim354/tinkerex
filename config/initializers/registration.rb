# REGISTRATION=open ON A SINGLE-LIBRARY BACKEND IS REFUSED AT BOOT (lib/tinkerex/registration.rb
# says why). The same shape as library_backend_check.rb: a misconfiguration that would only show
# on the first stranger's sign-up is worse than one that stops the boot. Skipped in test, where
# the unit test drives validate! directly.
Rails.application.config.after_initialize do
  Tinkerex::Registration.validate! unless Rails.env.test?
end
