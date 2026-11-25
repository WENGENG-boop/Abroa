# P4 notification emails deliberately contain no private financial fields,
# project names, recipient-chosen content or account links.
class AbroaNotificationMailer < ApplicationMailer
  def generic(recipient:)
    mail(to: recipient.email,
      subject: "Abroa: new account notification",
      body: "A new notification is available. Sign in to your Abroa account and open your notification inbox to review it.\n",
      content_type: "text/plain; charset=UTF-8")
  end
end
