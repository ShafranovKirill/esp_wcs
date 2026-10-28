defmodule BastionWeb.ConnectLive do
  use BastionWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    port = Bastion.Link.port()

    addresses =
      Enum.map(Bastion.PKI.device_addresses(), fn host ->
        if String.contains?(host, ":"), do: "[#{host}]:#{port}", else: "#{host}:#{port}"
      end)

    {:ok,
     assign(socket,
       page_title: gettext("How to connect"),
       addresses: addresses,
       bastion_code: Bastion.PKI.bastion_code(),
       mdns: Bastion.Discovery.method()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      locale={@locale}
      current_path={@current_path}
    >
      <div>
        <h1 class="text-2xl font-semibold">{gettext("How to connect a device")}</h1>
        <p class="text-sm text-base-content/60">
          {gettext(
            "The device connects to the bastion itself over Wi-Fi; the connection is encrypted and mutually authenticated."
          )}
        </p>
      </div>

      <div class="grid gap-6 lg:grid-cols-[1fr_22rem]">
        <ol class="space-y-3" id="steps">
          <.step n={1} title={gettext("Open the device setup")}>
            {gettext(
              "Hold the button on the device for 5 seconds and release it. The LED starts breathing blue."
            )}
          </.step>
          <.step n={2} title={gettext("Join the setup Wi-Fi")}>
            {gettext(
              "Connect your phone or laptop to the “ESP-WCS-XXXX” network and open https://192.168.4.1 — the browser warns about the certificate once."
            )}
          </.step>
          <.step n={3} title={gettext("Choose Bastion connection")}>
            {gettext(
              "Sign in, choose Bastion connection and connect the device to a Wi-Fi network from which this bastion is reachable."
            )}
          </.step>
          <.step n={4} title={gettext("Enter the bastion address")}>
            {gettext(
              "Copy one of the addresses on the right. bastion.local works if mDNS is available in the network, otherwise use the IP address."
            )}
            <span :if={@mdns == :off} class="text-warning" id="mdns-off">
              {gettext("mDNS is turned off on this bastion (BASTION_MDNS=off).")}
            </span>
          </.step>
          <.step n={5} title={gettext("Compare the bastion code")}>
            {gettext(
              "After “Check” the wizard shows the bastion code. It must match the code on the right — otherwise do not continue."
            )}
          </.step>
          <.step n={6} title={gettext("Approve the request")}>
            {gettext(
              "Apply the settings. The device sends a request — approve it on the Devices page after comparing the device code with the last step of the wizard."
            )}
          </.step>
        </ol>

        <aside class="space-y-4">
          <div class="card border border-base-300 bg-base-100">
            <div class="card-body gap-3 p-4">
              <h2 class="font-semibold">{gettext("Bastion address")}</h2>
              <ul class="space-y-2" id="addresses">
                <li
                  :for={{address, i} <- Enum.with_index(@addresses)}
                  class="flex items-center justify-between gap-2"
                >
                  <code class="truncate font-mono text-sm">{address}</code>
                  <.copy_button id={"copy-address-#{i}"} text={address} />
                </li>
              </ul>
              <p :if={@addresses == []} class="text-sm text-warning">
                {gettext("No network addresses found. Set BASTION_HOSTS in .env.")}
              </p>
            </div>
          </div>

          <div class="card border border-success/40 bg-base-100">
            <div class="card-body gap-2 p-4">
              <h2 class="flex items-center gap-2 font-semibold">
                <.icon name="hero-shield-check" class="size-5 text-success" /> {gettext(
                  "Bastion code"
                )}
              </h2>
              <div class="py-1">
                <.code code={@bastion_code} size="lg" id="connect-bastion-code" />
              </div>
              <p class="text-xs text-base-content/60">
                {gettext(
                  "The device remembers the bastion by this code and will not connect to anything else."
                )}
              </p>
            </div>
          </div>

          <div class="card border border-base-300 bg-base-100">
            <div class="card-body gap-2 p-4">
              <h2 class="font-semibold">{gettext("Root certificate")}</h2>
              <p class="text-sm text-base-content/70">
                {gettext(
                  "Install it as a trusted root on your computer so the browser stops warning about this bastion."
                )}
              </p>
              <a
                href={~p"/ca.crt"}
                class="btn btn-sm"
                download="esp-wcs-bastion-ca.crt"
                id="download-ca"
              >
                <.icon name="hero-arrow-down-tray" class="size-4" /> {gettext("Download")}
              </a>
              <.link href={~p"/ca"} class="link text-sm" id="ca-instructions">
                {gettext("How to install it")}
              </.link>
            </div>
          </div>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  attr :n, :integer, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp step(assigns) do
    ~H"""
    <li class="flex gap-4 rounded-box border border-base-300 bg-base-100 p-4">
      <span class="grid size-8 shrink-0 place-items-center rounded-full bg-primary/10 font-semibold text-primary">
        {@n}
      </span>
      <div>
        <h3 class="font-medium">{@title}</h3>
        <p class="mt-1 text-sm text-base-content/70">{render_slot(@inner_block)}</p>
      </div>
    </li>
    """
  end
end
