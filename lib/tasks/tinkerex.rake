# Console doors for a server with no mail, or with no admin signed in to do the same at Settings →
# Users (docs/INSTALL.md section 4). The password is read from TINKEREX_PASSWORD so it never sits in
# argv — `ps`, shell history and the deploy log all see argv.
namespace :tinkerex do
  # A lambda, not a `def`: a method defined inside a rake namespace block lands on Object,
  # process-wide, and every other rake file and the app itself can then see it.
  tinkerex_password = lambda do
    pw = ENV["TINKEREX_PASSWORD"].to_s
    abort "set TINKEREX_PASSWORD (#{Devise.password_length.min}+ characters); never pass it on the command line" if pw.length < Devise.password_length.min
    pw
  end

  desc "Create a confirmed account: bin/rails tinkerex:owner[EMAIL] with TINKEREX_PASSWORD set"
  task :owner, [ :email ] => :environment do |_t, args|
    email = args[:email].to_s.strip.downcase
    abort "usage: bin/rails tinkerex:owner[EMAIL]" if email.blank?
    abort "#{email} already exists — use tinkerex:password[EMAIL] to reset it" if User.exists?(email:)
    pw = tinkerex_password.call
    # The first account on a fresh server triggers the first library scan (Library::ScanJob
    # .enqueue_first_for says why it is the door's job). Decided before the create, because
    # afterwards there is always an account.
    first = !User.exists?
    # The first account is the admin (Settings → Users), as the sign-up form's is.
    user = User.create!(email:, password: pw, confirmed_at: Time.current, admin: first)
    # An operator at a console chose the mount by mounting it (K §3): confirm it, so the first scan
    # below is not paused waiting for a browser. After the create, so an account that fails to
    # save confirms nothing.
    Tinkerex::LibraryRoot.clear! if first && Tinkerex::LibraryRoot.pending?
    Library::ScanJob.enqueue_first_for(user) if first
    puts "created #{email} (confirmed)"
  end

  desc "Reset a password and confirm the account: bin/rails tinkerex:password[EMAIL] with TINKEREX_PASSWORD set"
  task :password, [ :email ] => :environment do |_t, args|
    email = args[:email].to_s.strip.downcase
    u = User.find_by(email:) or abort "no account #{email.inspect}"
    pw = tinkerex_password.call
    u.update!(password: pw, confirmed_at: u.confirmed_at || Time.current)
    puts "#{email} updated"
  end

  # THE RECOVERY DOOR for a server with no admin: one whose accounts all came from single sign-on
  # (User.from_omniauth is not an admin door -- the provider decides who signs in, not who
  # administers), or one restored from before admins existed with its oldest account gone.
  desc "Make an account an admin: bin/rails tinkerex:admin[EMAIL]"
  task :admin, [ :email ] => :environment do |_t, args|
    email = args[:email].to_s.strip.downcase
    abort "usage: bin/rails tinkerex:admin[EMAIL]" if email.blank?
    u = User.find_by(email:) or abort "no account #{email.inspect}"
    # Strangers are signed into the demo by one click; User#can_manage_accounts? ignores its flag.
    abort "#{email} is the shared demo account (DEMO_ACCOUNT_EMAIL) and cannot be an admin" if Tinkerex::Demo.demo?(u)
    u.update!(admin: true)
    puts "#{email} is an admin"
  end

  # THE PUBLIC DEMO (Tinkerex::DemoReset). Both tasks take the address from DEMO_ACCOUNT_EMAIL, never
  # argv: that setting is what makes an account the demo, so a task aimed anywhere else would wipe an
  # account the deployment does not treat as one.
  namespace :demo do
    demo_email = lambda do
      email = ENV["DEMO_ACCOUNT_EMAIL"].to_s.strip.downcase
      if email.blank?
        abort "set DEMO_ACCOUNT_EMAIL to the demo account's address first: it turns demo mode on, " \
              "and these tasks wipe and re-seed the account it names"
      end
      email
    end

    # A refusal has changed nothing; it is said in its own words and exits non-zero.
    run_reset = lambda do |user|
      fresh = Tinkerex::DemoReset.new(user:).call
      puts "#{fresh.email} reset from db/seeds/demo (now user #{fresh.id})"
    rescue Tinkerex::DemoReset::Refused => e
      abort "refused: #{e.message}"
    end

    desc "Create the demo account DEMO_ACCOUNT_EMAIL names (if absent) and seed its library: bin/rails tinkerex:demo:setup"
    task setup: :environment do
      email = demo_email.call
      user = User.find_by(email:)
      unless user
        # ASKED BEFORE MINTING, not left to the reset: on a library other accounts share, the account
        # alone is the harm — the next scan indexes their files into it, and the demo button signs
        # strangers in to it.
        why = Tinkerex::DemoReset.refusal
        abort "refused: #{why}" if why
        user = Tinkerex::DemoReset.create_account!(email)
        # THE DEMO IS THE ONLY ACCOUNT HERE (the refusal above saw to that) and it may not change the
        # library folder (Settings::LibraryController), so on a fresh share install the console
        # confirms the mount for it, as tinkerex:owner does -- or every page would send the demo to a
        # choice it is refused (found in review).
        Tinkerex::LibraryRoot.clear! if Tinkerex::LibraryRoot.pending?
        puts "created #{email} (confirmed, handle #{Tinkerex::DemoReset::HANDLE}, a password nobody is told)"
      end
      run_reset.call(user)
    end

    desc "Wipe the demo account's library and re-seed it from db/seeds/demo, as the nightly job does: bin/rails tinkerex:demo:reset"
    task reset: :environment do
      email = demo_email.call
      user = User.find_by(email:) or abort "no account #{email}: run bin/rails tinkerex:demo:setup first"
      run_reset.call(user)
    end
  end
end
