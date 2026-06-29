from apps.base import AppProfile
from job import AuthMethod

zoom_profile = AppProfile(
    name="Zoom",
    app_type="hybrid",
    supported_methods=[AuthMethod.sso, AuthMethod.user_pass, AuthMethod.skip],
    executable_hints=["Zoom.exe", "zoom.exe"],
    launch_command="start zoommtg://",

    sso_instructions="""
Open the Zoom desktop application. If Zoom is already running, bring it to the foreground.
If Zoom shows a main home/meetings screen with no sign-in prompt, the user is already signed in — report success immediately.

If Zoom shows a "You previously signed in as [email]" screen with an arrow (→) button:
  - If the displayed email matches the target user, click the arrow (→) button to continue signing in as that user.
  - If the displayed email does NOT match the target user, click "Sign into a different account" and proceed with the normal sign-in flow below.

If a sign-in screen is shown:
  1. Click "Sign In".
  2. Look for "SSO", "Sign In with SSO", or "Continue with SSO". Click it.
  3. In the "Company Domain" or "Your company's domain" field, type the sso_domain from the job profile.
     Do not add ".zoom.us" — just the slug (e.g. "acmecorp").
  4. Click "Continue".
  5. The default browser will open with an SSO redirect. Continue the login flow in the browser.
  6. If the browser SSO completes and Zoom re-opens to the home screen, the sign-in succeeded.
Stop immediately — do not click anything — if you see any of the following in Zoom or the browser:
  - Any MFA, two-factor, or authenticator prompt
  - A password entry field (do not enter passwords in SSO flow)
  - Admin consent or permissions approval
  - CAPTCHA
  - Terms of service acceptance
  - Password reset or account recovery
  - Any payment or billing screen
  - Any browser pop-up or prompt you do not recognize
Report what you see on screen when stopping.
""",

    user_pass_instructions="""
Open the Zoom desktop application.
If Zoom is already signed in (home screen visible with left sidebar showing Home, Chat, Phone, etc.), report success immediately.

If Zoom shows a "You previously signed in as [email]" screen with an arrow (→) button:
  - If the displayed email matches the target user, click the arrow (→) button. Then wait 4 seconds, take a screenshot, and check if the home screen appeared. If yes, report success.
  - If the displayed email does NOT match the target user, click "Sign into a different account" and proceed with the sign-in flow below.

If a sign-in screen is shown:
  1. Click "Sign In".
  2. Enter the username in the email field.
  3. Tab to the password field (or click it), then enter the password.
  4. Click the "Sign In" button.
  5. Wait 5 seconds, then take a screenshot.
  6. If the home screen is visible, report success immediately — do NOT click anything else.

IMPORTANT: After clicking Sign In, do not press alt+Tab, do not look for a browser, do not click anything until you have taken a screenshot and assessed the result. Zoom user/password sign-in does not open a browser.

The Zoom AI panel on the right side of the screen saying "Sign in to start asking questions" does NOT mean you are signed out — ignore it completely. Only look at the LEFT side of the screen for the main Zoom navigation (Home, Chat, Phone tabs).

Stop immediately if you see MFA, 2FA, CAPTCHA, password reset, or any unexpected prompt.
""",

    skip_instructions="""
Do not attempt to sign in.
Take a screenshot and report the current sign-in state of Zoom:
- If signed in: report success with the visible account name or avatar.
- If not signed in: report skipped with a description of what is visible.
""",

    success_criteria=[
        "Left sidebar visible with Home, Chat, Phone, Docs, Whiteboards, or Clips tabs",
        "User profile picture or avatar visible in top-left or top-right of the main Zoom window",
        "No sign-in screen or 'Sign In' button visible in the main Zoom window",
    ],

    stop_conditions=[
        "multi-factor", "two-factor", "2fa", "mfa", "authenticator",
        "verify your identity", "verification code", "enter code",
        "password reset", "change your password", "account recovery",
        "admin consent", "approve permissions", "grant access",
        "captcha", "prove you're not a robot", "i'm not a robot",
        "terms of service", "terms and conditions", "privacy policy",
        "payment", "billing", "credit card",
        "something went wrong", "error signing in",
    ],
)
