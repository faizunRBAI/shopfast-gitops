package xyz.royalbengal.shopfast.api;

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

    @Test
    void helloReturnsServiceIdentity() throws Exception {
        mockMvc.perform(get("/api/hello"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.service").value("shopfast"))
                .andExpect(jsonPath("$.message").value("Hello from ShopFast"))
                .andExpect(jsonPath("$.releaseColor").exists())
                .andExpect(jsonPath("$.version").exists());
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
