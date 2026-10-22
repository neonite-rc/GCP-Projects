# Maintenance page for the DR site — static nginx, listens on 8080
# (Cloud Run's default container port). Scale-to-zero keeps this at $0/mo
# until a disaster actually sends traffic here.
FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html

# Run nginx master as non-root (Cloud Run allows any UID, least privilege
# costs nothing here).
RUN chown -R nginx:nginx /var/cache/nginx /usr/share/nginx/html \
    && touch /run/nginx.pid && chown nginx:nginx /run/nginx.pid
USER nginx

EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
