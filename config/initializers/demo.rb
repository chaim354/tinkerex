# A DEMO_MAX_UPLOAD_BYTES THAT IS NOT A WHOLE NUMBER OF BYTES IS REFUSED AT BOOT while demo mode is
# on (lib/tinkerex/demo.rb says why). The same shape as registration.rb: a typo that would otherwise
# surface on a visitor's first upload stops the deploy instead. Skipped in test, where
# test/lib/demo_test.rb drives validate! directly.
Rails.application.config.after_initialize do
  Tinkerex::Demo.validate! unless Rails.env.test?
end
