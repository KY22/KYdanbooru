require 'test_helper'

class SessionsControllerTest < ActionDispatch::IntegrationTest
  context "the sessions controller" do
    setup do
      @user = create(:user, name: "foobar", password: "password", email_address_attributes: { address: "Foo.Bar+nospam@Googlemail.com" })
    end

    context "new action" do
      should "render" do
        get new_session_path
        assert_response :success
      end
    end

    context "create action" do
      should "log the user in when given the correct password" do
        post session_path, params: { name: @user.name, password: "password" }

        assert_redirected_to posts_path
        assert_equal(@user.id, session[:user_id])
        assert_not_nil(@user.reload.last_ip_addr)
        assert_equal(true, @user.user_events.login.exists?)
      end

      should "log the user in when given their email address" do
        post session_path, params: { name: "Foo.Bar+nospam@Googlemail.com", password: "password" }

        assert_redirected_to posts_path
        assert_equal(@user.id, session[:user_id])
        assert_not_nil(@user.reload.last_ip_addr)
        assert_equal(true, @user.user_events.login.exists?)
      end

      should "normalize the user's email address when logging in" do
        post session_path, params: { name: "foobar@gmail.com", password: "password" }

        assert_redirected_to posts_path
        assert_equal(@user.id, session[:user_id])
        assert_not_nil(@user.reload.last_ip_addr)
        assert_equal(true, @user.user_events.login.exists?)
      end

      should "be case-insensitive towards the user's name when logging in" do
        post session_path, params: { name: @user.name.upcase, password: "password" }

        assert_redirected_to posts_path
        assert_equal(@user.id, session[:user_id])
        assert_not_nil(@user.reload.last_ip_addr)
        assert_equal(true, @user.user_events.login.exists?)
      end

      should "not log the user in when given an incorrect username + password combination" do
        post session_path, params: { name: @user.name, password: "wrong" }

        assert_response 401
        assert_nil(nil, session[:user_id])
        assert_equal(true, @user.user_events.failed_login.exists?)
      end

      should "not log the user in when given an incorrect email" do
        post session_path, params: { name: "foo@gmail.com", password: "password" }

        assert_response 401
        assert_nil(nil, session[:user_id])
      end

      should "not log the user in when given an incorrect username" do
        post session_path, params: { name: "dne", password: "password" }

        assert_response 401
        assert_nil(nil, session[:user_id])
      end

      should "not log the user in when attempting to login to a privileged account from a proxy" do
        user = create(:approver_user, password: "password")
        ActionDispatch::Request.any_instance.stubs(:remote_ip).returns("1.1.1.1")

        post session_path, params: { name: user.name, password: "password" }

        assert_response 401
        assert_nil(nil, session[:user_id])
      end

      should "not log the user in when attempting to login to a inactive account from a proxy" do
        user = create(:user, password: "password", last_logged_in_at: 1.year.ago)
        ActionDispatch::Request.any_instance.stubs(:remote_ip).returns("1.1.1.1")

        post session_path, params: { name: user.name, password: "password" }

        assert_response 401
        assert_nil(nil, session[:user_id])
      end

      should "not log the user in yet if they have 2FA enabled" do
        user = create(:user_with_2fa, password: "password")

        post session_path, params: { name: user.name, password: "password" }

        assert_response :success
        assert_nil(nil, session[:user_id])
        assert_equal(true, user.user_events.totp_login_pending_verification.exists?)
      end

      should "redirect the user when given an url param" do
        post session_path, params: { name: @user.name, password: "password", url: tags_path }
        assert_redirected_to tags_path
      end

      should "not allow redirects to protocol-relative URLs" do
        post session_path, params: { name: @user.name, password: "password", url: "//example.com" }
        assert_response 403
      end

      should "not allow deleted users to login" do
        @user.update!(is_deleted: true)
        post session_path, params: { name: @user.name, password: "password" }

        assert_response 401
        assert_nil(nil, session[:user_id])
        assert_equal(true, @user.user_events.failed_login.exists?)
      end

      should "not allow IP banned users to login" do
        @ip_ban = create(:ip_ban, category: :full, ip_addr: "1.2.3.4")
        post session_path, params: { name: @user.name, password: "password" }, headers: { REMOTE_ADDR: "1.2.3.4" }

        assert_response 403
        assert_not_equal(@user.id, session[:user_id])
        assert_equal(1, @ip_ban.reload.hit_count)
        assert(@ip_ban.last_hit_at > 1.minute.ago)
      end

      should "allow partial IP banned users to login" do
        @ip_ban = create(:ip_ban, category: :partial, ip_addr: "1.2.3.4")
        post session_path, params: { name: @user.name, password: "password" }, headers: { REMOTE_ADDR: "1.2.3.4" }

        assert_redirected_to posts_path
        assert_equal(@user.id, session[:user_id])
        assert_equal(0, @ip_ban.reload.hit_count)
        assert_nil(@ip_ban.last_hit_at)
      end

      should "ignore deleted IP bans when logging in" do
        @ip_ban = create(:ip_ban, is_deleted: true, category: :full, ip_addr: "1.2.3.4")
        post session_path, params: { name: @user.name, password: "password" }, headers: { REMOTE_ADDR: "1.2.3.4" }

        assert_redirected_to posts_path
        assert_equal(@user.id, session[:user_id])
        assert_equal(0, @ip_ban.reload.hit_count)
        assert_nil(@ip_ban.last_hit_at)
      end

      should "rate limit logins to 10 per minute per IP" do
        Danbooru.config.stubs(:rate_limits_enabled?).returns(true)
        freeze_time

        10.times do
          post session_path, params: { name: @user.name, password: "password" }, headers: { REMOTE_ADDR: "1.2.3.4" }
          assert_redirected_to posts_path
          assert_equal(@user.id, session[:user_id])
          delete_auth session_path, @user
        end

        post session_path, params: { name: @user.name, password: "password" }, headers: { REMOTE_ADDR: "1.2.3.4" }
        assert_response 429
        assert_not_equal(@user.id, session[:user_id])

        travel 59.seconds
        post session_path, params: { name: @user.name, password: "password" }, headers: { REMOTE_ADDR: "1.2.3.4" }
        assert_response 429
        assert_not_equal(@user.id, session[:user_id])

        travel 65.seconds
        post session_path, params: { name: @user.name, password: "password" }, headers: { REMOTE_ADDR: "1.2.3.4" }
        assert_redirected_to posts_path
        assert_equal(@user.id, session[:user_id])
      end
    end

    context "verify_totp action" do
      should "log the user in if they enter the correct 2FA code" do
        @user = create(:user_with_2fa, password: "password")

        post verify_totp_session_path, params: { totp: { user_id: @user.signed_id(purpose: :verify_totp), code: @user.totp.code, url: users_path } }

        assert_redirected_to users_path
        assert_equal(@user.id, session[:user_id])
        assert_not_nil(@user.reload.last_ip_addr)
        assert_equal(true, @user.user_events.totp_login.exists?)
      end

      should "log the user in if they enter a 2FA code that was generated less than 30 seconds ago" do
        @user = create(:user_with_2fa, password: "password")
        code = travel_to(25.seconds.ago) { @user.totp.code }

        post verify_totp_session_path, params: { totp: { user_id: @user.signed_id(purpose: :verify_totp), code: code, url: users_path } }

        assert_redirected_to users_path
        assert_equal(@user.id, session[:user_id])
        assert_not_nil(@user.reload.last_ip_addr)
        assert_equal(true, @user.user_events.totp_login.exists?)
      end

      should "log the user in if they enter a 2FA code that was generated less than 30 seconds in the future" do
        @user = create(:user_with_2fa, password: "password")
        code = travel_to(25.seconds.from_now) { @user.totp.code }

        post verify_totp_session_path, params: { totp: { user_id: @user.signed_id(purpose: :verify_totp), code: code, url: users_path } }

        assert_redirected_to users_path
        assert_equal(@user.id, session[:user_id])
        assert_not_nil(@user.reload.last_ip_addr)
        assert_equal(true, @user.user_events.totp_login.exists?)
      end

      should "not log the user in if they enter an incorrect 2FA code" do
        @user = create(:user_with_2fa, password: "password")

        post verify_totp_session_path, params: { totp: { user_id: @user.signed_id(purpose: :verify_totp), code: "invalid", url: users_path } }

        assert_response :success
        assert_nil(nil, session[:user_id])
        assert_equal(true, @user.user_events.totp_failed_login.exists?)
      end

      should "not log the user in if they enter a 2FA code that was generated more than a minute ago" do
        @user = create(:user_with_2fa, password: "password")
        code = travel_to(65.seconds.ago) { @user.totp.code }

        post verify_totp_session_path, params: { totp: { user_id: @user.signed_id(purpose: :verify_totp), code: code, url: users_path } }

        assert_response :success
        assert_nil(nil, session[:user_id])
        assert_equal(true, @user.user_events.totp_failed_login.exists?)
      end

      should "not log the user in if they enter a 2FA code that was generated more than a minute in the future" do
        @user = create(:user_with_2fa, password: "password")
        code = travel_to(65.seconds.from_now) { @user.totp.code }

        post verify_totp_session_path, params: { totp: { user_id: @user.signed_id(purpose: :verify_totp), code: code, url: users_path } }

        assert_response :success
        assert_nil(nil, session[:user_id])
        assert_equal(true, @user.user_events.totp_failed_login.exists?)
      end
    end

    context "destroy action" do
      should "clear the session" do
        delete_auth session_path, @user

        assert_redirected_to posts_path
        assert_nil(session[:user_id])
      end

      should "generate a logout event" do
        delete_auth session_path, @user

        assert_equal(true, @user.user_events.logout.exists?)
      end

      should "not fail if the user is already logged out" do
        delete session_path

        assert_redirected_to posts_path
        assert_nil(session[:user_id])
      end
    end

    context "sign_out action" do
      should "clear the session" do
        get_auth sign_out_session_path, @user
        assert_redirected_to posts_path
        assert_nil(session[:user_id])
      end
    end
  end
end
