package xyz.royalbengal.shopfast.api;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * ShopFast API.
 *
 * The response deliberately echoes the release colour and image tag injected by
 * the Helm chart. During a blue/green or canary rollout this is what proves
 * which revision actually served a given request.
 */
@RestController
@RequestMapping("/api")
public class HelloController {

    private final Counter helloCounter;

    @Value("${shopfast.release.color:unknown}")
    private String releaseColor;

    @Value("${shopfast.release.version:dev}")
    private String releaseVersion;

    public HelloController(MeterRegistry registry) {
        this.helloCounter = Counter.builder("shopfast_hello_requests_total")
                .description("Total number of requests served by /api/hello")
                .register(registry);
    }

    @GetMapping("/hello")
    public Map<String, Object> hello() {
        helloCounter.increment();

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("message", "Hello from ShopFast");
        body.put("service", "shopfast");
        body.put("releaseColor", releaseColor);
        body.put("version", releaseVersion);
        body.put("timestamp", Instant.now().toString());
        return body;
    }
}
