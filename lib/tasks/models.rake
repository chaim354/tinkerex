namespace :models do
  desc "Catalogue every model-role file in the library (MODEL_CATALOG_MAX_MODELS to raise the cap)"
  task catalog: :environment do
    User.find_each do |user|
      run = Maker::ModelIntake.for_user(user:)
      puts "user #{user.id}: created #{run.created}, attached #{run.attached}, " \
           "skipped #{run.skipped} (no shelf above them), status #{run.status}"
      puts "  capped at #{run.cap} - run again to continue" if run.status == :capped
    end
  end
end
