package xyz.royalbengal.shopfast.api;

import io.micrometer.core.instrument.MeterRegistry;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.core.io.ClassPathResource;
import org.springframework.test.web.servlet.MockMvc;

import java.nio.charset.StandardCharsets;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.forwardedUrl;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@SpringBootTest
@AutoConfigureMockMvc
class HelloControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @Autowired
    private MeterRegistry meterRegistry;

    @Test
    void helloReturnsServiceIdentity() throws Exception {
        mockMvc.perform(get("/api/hello"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.service").value("shopfast"))
                .andExpect(jsonPath("$.message").value("Hello from ShopFast"))
                .andExpect(jsonPath("$.releaseColor").exists())
                .andExpect(jsonPath("$.version").exists())
                .andExpect(jsonPath("$.timestamp").exists());
    }

    /**
     * The release identity fields are not decoration: the blue/green and canary
     * dashboards prove "which revision served this request" from exactly these
     * two values. The defaults come from @Value fallbacks
     * (shopfast.release.color:unknown / shopfast.release.version:dev), so in a
     * test context with no injected env they must still be PRESENT and
     * non-blank rather than null.
     */
    @Test
    void helloAlwaysCarriesReleaseIdentity() throws Exception {
        mockMvc.perform(get("/api/hello"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.releaseColor").isNotEmpty())
                .andExpect(jsonPath("$.version").isNotEmpty());
    }

    /**
     * shopfast_hello_requests_total is scraped by VictoriaMetrics and is the
     * per-release request signal on the Release Comparison dashboard. Nothing
     * asserted that it actually increments, so a refactor that dropped the
     * Counter.increment() call would have left the dashboard silently flat
     * while every other test stayed green.
     */
    @Test
    void helloIncrementsTheRequestCounter() throws Exception {
        double before = meterRegistry.counter("shopfast_hello_requests_total").count();

        mockMvc.perform(get("/api/hello")).andExpect(status().isOk());

        double after = meterRegistry.counter("shopfast_hello_requests_total").count();
        assertThat(after).isEqualTo(before + 1.0d);
    }

    /**
     * Spring Boot's WelcomePageHandlerMapping serves the static landing page by
     * FORWARDING "/" to index.html. MockMvc records the forward but does not
     * execute it (there is no real servlet container), so the recorded response
     * has no content type or body — asserting on those would fail even though a
     * browser renders the page correctly.
     *
     * The observable contract at this layer is therefore: 200 + forward to
     * index.html.
     */
    @Test
    void rootForwardsToTheLandingPage() throws Exception {
        mockMvc.perform(get("/"))
                .andExpect(status().isOk())
                .andExpect(forwardedUrl("index.html"));
    }

    /**
     * Guards the other half of the contract: the forwarded resource must exist
     * and actually be the ShopFast UI. Without this, emptying or deleting
     * index.html would still leave the forward assertion above passing.
     */
    @Test
    void landingPageResourceIsRealHtml() throws Exception {
        ClassPathResource page = new ClassPathResource("static/index.html");
        assertThat(page.exists()).isTrue();

        String html = new String(page.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
        assertThat(html).contains("<!DOCTYPE html>");
        assertThat(html).contains("ShopFast");
        // The landing page must link the endpoints the platform exposes.
        assertThat(html).contains("/api/hello");
        assertThat(html).contains("/actuator/health");
        assertThat(html).contains("/actuator/prometheus");
    }
}
