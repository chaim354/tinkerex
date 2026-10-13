# Console doors for a server with no mail (docs/DEPLOY.md "Accounts"). The password is read from
# TINKEREX_PASSWORD so it never sits in argv — `ps`, shell history and the deploy log all see argv.
namespace :tinkerex do
  def tinkerex_password!
    pw = ENV["TINKEREX_PASSWORD"].to_s
    abort "set TINKEREX_PASSWORD (#{Devise.password_length.min}+ characters); never pass it on the command line" if pw.length < Devise.password_length.min
    pw
  end

  desc "Create a confirmed account: bin/rails tinkerex:owner[EMAIL] with TINKEREX_PASSWORD set"
  task :owner, [ :email ] => :environment do |_t, args|
    email = args[:email].to_s.strip.downcase
    abort "usage: bin/rails tinkerex:owner[EMAIL]" if email.blank?
    abort "#{email} already exists — use tinkerex:password[EMAIL] to reset it" if User.exists?(email:)
    pw = tinkerex_password!
    User.create!(email:, password: pw, confirmed_at: Time.current)
    puts "created #{email} (confirmed)"
  end

  desc "Reset a password and confirm the account: bin/rails tinkerex:password[EMAIL] with TINKEREX_PASSWORD set"
  task :password, [ :email ] => :environment do |_t, args|
    email = args[:email].to_s.strip.downcase
    u = User.find_by(email:) or abort "no account #{email.inspect}"
    pw = tinkerex_password!
    u.update!(password: pw, confirmed_at: u.confirmed_at || Time.current)
    puts "#{email} updated"
  end
end
